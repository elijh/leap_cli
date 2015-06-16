
module LeapCli
  module Commands

    desc "Compile generated files."
    command [:compile, :c] do |c|
      c.desc 'Compiles node configuration files into hiera files used for deployment.'
      c.arg_name 'ENVIRONMENT', :optional => true
      c.command :all do |all|
        all.action do |global_options,options,args|
          environment = args.first
          if !LeapCli.leapfile.environment.nil? && !environment.nil? && environment != LeapCli.leapfile.environment
            bail! "You cannot specify an ENVIRONMENT argument while the environment is pinned."
          end
          if environment
            if manager.environment_names.include?(environment)
              compile_hiera_files(manager.filter([environment]), false)
            else
              bail! "There is no environment named `#{environment}`."
            end
          else
            clean_export = LeapCli.leapfile.environment.nil?
            compile_hiera_files(manager.filter, clean_export)
          end
        end
      end

      c.desc "Compile a DNS zone file for your provider."
      c.command :zone do |zone|
        zone.action do |global_options, options, args|
          compile_zone_file
        end
      end

      c.default_command :all
    end

    protected

    #
    # a "clean" export of secrets will also remove keys that are no longer used,
    # but this should not be done if we are not examining all possible nodes.
    #
    def compile_hiera_files(nodes, clean_export)
      update_compiled_ssh_configs # must come first
      manager.export_nodes(nodes)
      manager.export_secrets(clean_export)
    end

    def update_compiled_ssh_configs
      generate_monitor_ssh_keys
      update_authorized_keys
      update_known_hosts
    end

    ##
    ## SSH
    ##

    #
    # generates a ssh key pair that is used only by remote monitors
    # to connect to nodes and run certain allowed commands.
    #
    # every node has the public monitor key added to their authorized
    # keys, and every monitor node has a copy of the private monitor key.
    #
    def generate_monitor_ssh_keys
      priv_key_file = path(:monitor_priv_key)
      pub_key_file  = path(:monitor_pub_key)
      unless file_exists?(priv_key_file, pub_key_file)
        ensure_dir(File.dirname(priv_key_file))
        ensure_dir(File.dirname(pub_key_file))
        cmd = %(ssh-keygen -N '' -C 'monitor' -t rsa -b 4096 -f '%s') % priv_key_file
        assert_run! cmd
        if file_exists?(priv_key_file, pub_key_file)
          log :created, priv_key_file
          log :created, pub_key_file
        else
          log :failed, 'to create monitor ssh keys'
        end
      end
    end

    #
    # Compiles the authorized keys file, which gets installed on every during init.
    # Afterwards, puppet installs an authorized keys file that is generated differently
    # (see authorized_keys() in macros.rb)
    #
    def update_authorized_keys
      buffer = StringIO.new
      keys = Dir.glob(path([:user_ssh, '*']))
      if keys.empty?
        bail! "You must have at least one public SSH user key configured in order to proceed. See `leap help add-user`."
      end
      if file_exists?(path(:monitor_pub_key))
        keys << path(:monitor_pub_key)
      end
      keys.sort.each do |keyfile|
        ssh_type, ssh_key = File.read(keyfile).strip.split(" ")
        buffer << ssh_type
        buffer << " "
        buffer << ssh_key
        buffer << " "
        buffer << Path.relative_path(keyfile)
        buffer << "\n"
      end
      write_file!(:authorized_keys, buffer.string)
    end

    #
    # generates the known_hosts file.
    #
    # we do a 'late' binding on the hostnames and ip part of the ssh pub key record in order to allow
    # for the possibility that the hostnames or ip has changed in the node configuration.
    #
    def update_known_hosts
      buffer = StringIO.new
      buffer << "#\n"
      buffer << "# This file is automatically generated by the command `leap`. You should NOT modify this file.\n"
      buffer << "# Instead, rerun `leap node init` on whatever node is causing SSH problems.\n"
      buffer << "#\n"
      manager.nodes.keys.sort.each do |node_name|
        node = manager.nodes[node_name]
        hostnames = [node.name, node.domain.internal, node.domain.full, node.ip_address].join(',')
        pub_key = read_file([:node_ssh_pub_key,node.name])
        if pub_key
          buffer << [hostnames, pub_key].join(' ')
          buffer << "\n"
        end
      end
      write_file!(:known_hosts, buffer.string)
    end

    ##
    ## ZONE FILE
    ##

    def relative_hostname(fqdn)
      @domain_regexp ||= /\.?#{Regexp.escape(provider.domain)}$/
      fqdn.sub(@domain_regexp, '')
    end

    #
    # serial is any number less than 2^32 (4294967296)
    #
    def compile_zone_file
      hosts_seen = {}
      f = $stdout
      f.puts ZONE_HEADER % {:domain => provider.domain, :ns => provider.domain, :contact => provider.contacts.default.first.sub('@','.')}
      max_width = manager.nodes.values.inject(0) {|max, node| [max, relative_hostname(node.domain.full).length].max }
      put_line = lambda do |host, line|
        host = '@' if host == ''
        f.puts("%-#{max_width}s %s" % [host, line])
      end

      f.puts ORIGIN_HEADER
      # 'A' records for primary domain
      manager.nodes[:environment => '!local'].each_node do |node|
        if node.dns['aliases'] && node.dns.aliases.include?(provider.domain)
          put_line.call "", "IN A      #{node.ip_address}"
        end
      end

      # NS records
      if provider['dns'] && provider.dns['nameservers']
        provider.dns.nameservers.each do |ns|
          put_line.call "", "IN NS #{ns}."
        end
      end

      # all other records
      manager.environment_names.each do |env|
        next if env == 'local'
        nodes = manager.nodes[:environment => env]
        next unless nodes.any?
        f.puts ENV_HEADER % (env.nil? ? 'default' : env)
        nodes.each_node do |node|
          if node.dns.public
            hostname = relative_hostname(node.domain.full)
            put_line.call relative_hostname(node.domain.full), "IN A      #{node.ip_address}"
          end
          if node.dns['aliases']
            node.dns.aliases.each do |host_alias|
              if host_alias != node.domain.full && host_alias != provider.domain
                put_line.call relative_hostname(host_alias), "IN CNAME  #{relative_hostname(node.domain.full)}"
              end
            end
          end
          if node.services.include? 'mx'
            put_line.call relative_hostname(node.domain.full_suffix), "IN MX 10  #{relative_hostname(node.domain.full)}"
          end
        end
      end
    end

    ENV_HEADER = %[
;;
;; ENVIRONMENT %s
;;

]

    ZONE_HEADER = %[
;;
;; BIND data file for %{domain}
;;

$TTL 600
$ORIGIN %{domain}.

@ IN SOA %{ns}. %{contact}. (
  0000          ; serial
  7200          ; refresh (  24 hours)
  3600          ; retry   (   2 hours)
  1209600       ; expire  (1000 hours)
  600 )         ; minimum (   2 days)
;
]

    ORIGIN_HEADER = %[
;;
;; ZONE ORIGIN
;;

]

  end
end