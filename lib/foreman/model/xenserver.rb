module Foreman::Model
  class Xenserver < ComputeResource
    validates_presence_of :url, :user, :password

    def provided_attributes
      super.merge({:uuid => :reference,
		   :mac => :mac})
    end

    def capabilities
      [:build]
    end

    def find_vm_by_uuid ref
      client.servers.get(ref)
    rescue ::Xenserver::RetrieveError => e
      raise(ActiveRecord::RecordNotFound)
    end

    # we default to destroy the VM's storage as well.
    def destroy_vm ref, args = { }
      find_vm_by_uuid(ref).destroy
    rescue ActiveRecord::RecordNotFound
      true
    end

    def self.model_name
      ComputeResource.model_name
    end

    def max_cpu_count
      hypervisor.host_cpus
    end

    # libvirt reports in KB
    def max_memory
      hypervisor.memory * 1024
    rescue => e
      logger.debug "unable to figure out free memory, guessing instead due to:#{e}"
      16*1024*1024*1024
    end

    def test_connection options = {}
      super
      errors[:url].empty? and hypervisor
    rescue => e
      disconnect rescue nil
      errors[:base] << e.message
    end

    def new_nic attr={ }
      client.networks.new attr
    end

    def new_volume attr={ }
      client.storage_repositories.new attr
    end

    def storage_pools
      client.storage_repositories rescue []
    end

    def interfaces
      client.interfaces rescue []
    end

    def networks
      client.networks rescue []
    end

    def templates
	    client.servers.templates rescue []
    end

    def new_vm attr={ }
        #file = File.open("/usr/share/foreman/log/avi", 'w')
        #file.write "#{attr}"

      test_connection
      return unless errors.empty?
      opts = vm_instance_defaults.merge(attr.to_hash).symbolize_keys

# convert rails nested_attributes into a plain hash
      [:networks, :volumes].each do |collection|
        nested_attrs = opts.delete("#{collection}_attributes".to_sym)
        opts[collection] = nested_attributes_for(collection, nested_attrs) if nested_attrs
      end
     opts.reject! { |k, v| v.nil? }
     client.servers.new opts
#      vm.memory_static_max = opts[:memory_static_max] if opts[:memory_static_max]
#      vm
    end

    def create_vm args = {}
      template_name = args[:templates][:print]
      subnet = Subnet.find(args[:subnet_id])
      vm = client.servers.create :name => args[:name], :template_name => template_name
      vm.hard_shutdown
      vm.refresh
      vm.set_attribute('xenstore_data',
      'vm-data'=>'',
       'vm-data/nameserver1'=>subnet.dns_primary,
       'vm-data/nameserver2'=>subnet.dns_secondary,
      'vm-data/ifs'=>'',
       'vm-data/ifs/0'=>'' ,
       'vm-data/ifs/0/netmask'=>subnet.mask,
       'vm-data/ifs/0/gateway'=>subnet.gateway,
       'vm-data/ifs/0/mac'=>vm.vifs.first.mac,
       'vm-data/ifs/0/ip'=>args[:free_ip]
      )
      # vm.set_attribute('xenstore_data', ''=>'')
      vm
    end

    def create_vm_asd args = { }
	opts = vm_instance_defaults.merge(args.to_hash).symbolize_keys
	#file = File.open("/usr/share/foreman/log/avi2", 'w')
	#file.write "args: #{args}\n"
	host = client.hosts.first
	net = client.networks.find { |n| n.name == "#{args[:VIFs][:print]}" }
	storage_repository = client.storage_repositories.find { |sr| sr.name == "#{args[:VBDs][:print]}" }
      	vdi = client.vdis.create :name => "#{args[:name]}-disk1",
	                       :storage_repository => storage_repository,
                              :description => "#{args[:name]}-disk1",
                              :virtual_size => '8589934592' # ~8GB in bytes
	mem = (512 * 1024 * 1024).to_s
      	vm = client.servers.new :name => args[:name],
				:affinity => host,
				#:networks => [net],
				:pv_bootloader => '',
				:hvm_boot_params => { :order => 'dn' },
				:HVM_boot_policy => 'BIOS order',
				:memory_static_max  => mem,
                                :memory_static_min  => mem,
                                :memory_dynamic_max => mem,
                                :memory_dynamic_min => mem
	#file.write "vm: #{vm.inspect}\n"
	#file.close
	vm.save :auto_start => false
	client.vbds.create :server => vm, :vdi => vdi
	net_config = {
		'MAC_autogenerated' => 'True',
		'VM' => vm.reference,
		'network' => net.reference,
		'MAC' => '',
		'device' => '0',
		'MTU' => '0',
		'other_config' => {},
		'qos_algorithm_type' => 'ratelimit',
		'qos_algorithm_params' => {}
		}
	client.create_vif_custom net_config
	vm.refresh
	vm.provision
	#vm.start
	vm

    rescue Fog::Errors::Error => e
      errors.add(:base, e.to_s)
      false
    end

    def console uuid
      vm = find_vm_by_uuid(uuid)
      raise "VM is not running!" unless vm.ready?
      password = random_password

      console = vm.service.consoles.find {|c| c.__vm == vm.reference && c.protocol == 'rfb'}
      raise "No console fore vm #{vm.name}" if console == nil

      session_ref = (vm.service.instance_variable_get :@connection).instance_variable_get :@credentials
      fullURL = "#{console.location}&session_id=#{session_ref}"
      tunnel = VNCTunnel.new fullURL
      tunnel.start

      WsProxy.start(:host => tunnel.host, :host_port => tunnel.port, :password => '').merge(:type => 'vnc', :name=> vm.name)

    rescue Error => e
      logger.warn e
      raise e
    end

    def hypervisor
      client.hosts.first
    end

    protected

    def client
      # WARNING potential connection leak
      tries ||= 3
      Thread.current[url] ||= ::Fog::Compute.new({:provider => 'XenServer', :xenserver_url => url, :xenserver_username => user, :xenserver_password => password})
    rescue ::Xenserver::RetrieveError
      Thread.current[url] = nil
      retry unless (tries -= 1).zero?
    end

    def disconnect
      client.terminate if Thread.current[url]
      Thread.current[url] = nil
    end

    def vm_instance_defaults
      super.merge(
        :memory     => 768*1024*1024,
        :boot_order => %w[network hd],
        :networks       => [new_nic],
        :storage_repositories    => [new_volume],
        :display    => { :type => 'vnc', :listen => Setting[:libvirt_default_console_address], :password => random_password, :port => '-1' }
      )
    end

    def create_storage_repositories args
      vols = []
      (storage_repositories = args[:storage_repositories]).each do |vol|
        vol.name       = "#{args[:prefix]}-disk#{storage_repositories.index(vol)+1}"
        vol.allocation = "0G"
        vol.save
        vols << vol
      end
      vols
    rescue => e
      logger.debug "Failure detected #{e}: removing already created storage_repositories" if vols.any?
      vols.each { |vol| vol.destroy }
      raise e
    end

  end
end
