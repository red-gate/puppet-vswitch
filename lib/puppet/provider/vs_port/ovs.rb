require 'puppet'

UUID_RE = /[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89aAbB][a-f0-9]{3}-[a-f0-9]{12}/

Puppet::Type.type(:vs_port).provide(:ovs) do
  desc 'Openvswitch port manipulation'

  has_feature :bonding

  commands :vsctl => 'ovs-vsctl'

  def exists?
    vsctl('list-ports', @resource[:bridge]).include? @resource[:port]
  rescue Puppet::ExecutionFailure => e
    return false
  end

  def create
    # create with first interface, other interfaces will be added later when synchronizing properties
    vsctl('--', '--id=@iface0', 'create', 'Interface', "name=#{@resource[:interface][0]}", '--', 'add-port', @resource[:bridge], @resource[:port], 'interfaces=@iface0')

    # synchronize properties
    # Only sync those properties actually supported by the provider. This
    # allows this provider to be used as a base class for providers not
    # supporting all properties.
    sync_properties = []
    if self.bonding?
      sync_properties += [:interface,
                          :bond_mode,
                          :lacp,
                          :lacp_time,
                         ]
    end
    for prop_name in sync_properties
      property = @resource.property(prop_name)
      property.sync unless property.safe_insync?(property.retrieve)
    end
  end

  def destroy
    vsctl('del-port', @resource[:bridge], @resource[:port])
  end

  def interface
    get_port_interface_column('name')
  end

  def interface=(value)
    # find interfaces we want to keep on the port
    keep = @resource.property(:interface).retrieve() & value
    keep_uids = keep.map { |iface| vsctl('get', 'Interface', iface, '_uuid').strip }
    new = value - keep
    args = ['--'] + new.each_with_index.map { |iface, i| ["--id=@#{i+1}", 'create', 'Interface', "name=#{iface}", '--'] }
    ifaces = (1..new.length).map { |i| "@#{i}" } + keep_uids
    args += ['set', 'Port', @resource[:port], "interfaces=#{ifaces.join(',')}"]
    vsctl(*args)
  end

  def bond_mode
    get_port_column('bond_mode')
  end

  def bond_mode=(value)
    set_port_column('bond_mode', value)
  end

  def lacp
    get_port_column('lacp')
  end

  def lacp=(value)
    set_port_column('lacp', value)
  end

  def lacp_time
    get_port_column('other_config:lacp-time')
  end

  def lacp_time=(value)
    set_port_column('other_config:lacp-time', value)
  end

  private

  def port_column_command(command, column, value=nil)
    if value
      vsctl(command, 'Port', @resource[:port], column, value)
    else
      vsctl('--if-exists', command, 'Port', @resource[:port], column)
    end
  end

  def get_port_column(column)
    value = port_column_command('get', column).strip
    if value == '[]' then '' else value end
  end

  def set_port_column(column, value)
    if ! value or value.empty?
      # columns with maps need special handling, single map entries
      # can be removed with the remove command
      column, key = column.split(':')
      if ! key
        port_column_command('clear', column)
      else
        port_column_command('remove', [column, key])
      end
    else
      port_column_command('set', "#{column}=#{value}")
    end
  end

  def get_port_interface_column(column)
    uuids = get_port_column('interfaces').scan(UUID_RE)
    uuids.map!{|id| vsctl('get', 'Interface', id, column).strip.tr('"', '')}
  end
end
