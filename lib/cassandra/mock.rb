require 'nokogiri'

class UUID
  def >=(other)
    other = nil if other == ''
    other = UUID.new(other) unless other.kind_of?(UUID)
    (self <=> other) >= 0
  end

  def <=(other)
    other = nil if other == ''
    other = UUID.new(other) unless other.kind_of?(UUID)
    (self <=> other) <= 0
  end
end

class Cassandra
  class Mock
    include ::Cassandra::Helpers
    include ::Cassandra::Columns

    def initialize(keyspace, servers=nil, options={})
      @keyspace = keyspace
      @column_name_class = {}
      @sub_column_name_class = {}
      @storage_xml = options[:storage_xml]
    end

    def clear_keyspace!
      @data = {}
    end

    def insert(column_family, key, hash, options = {})
      if @batch
        @batch << [:insert, column_family, key, hash, options]
      else
        raise ArgumentError if key.nil?
        if schema[column_family.to_s]['Type'] == 'Standard'
          insert_standard(column_family, key, hash)
        else
          insert_super(column_family, key, hash)
        end
      end
    end

    def insert_standard(column_family, key, hash)
      @data[column_family.to_sym] ||= OrderedHash.new
      if @data[column_family.to_sym][key]
        @data[column_family.to_sym][key] = OrderedHash[@data[column_family.to_sym][key].merge(hash).sort{|a,b| a[0] <=> b[0]}]
      else
        @data[column_family.to_sym][key] = OrderedHash[hash.sort{|a,b| a[0] <=> b[0]}]
      end
    end

    def insert_super(column_family, key, hash)
      @data[column_family.to_sym]      ||= OrderedHash.new
      @data[column_family.to_sym][key] ||= OrderedHash.new
      hash.keys.each do |sub_key|
        if @data[column_family.to_sym][key][sub_key]
          @data[column_family.to_sym][key][sub_key] = OrderedHash[@data[column_family.to_sym][key][sub_key].merge(hash[sub_key]).sort{|a,b| a[0] <=> b[0]}]
        else
          @data[column_family.to_sym][key][sub_key] = OrderedHash[hash[sub_key].sort{|a,b| a[0] <=> b[0]}]
        end
      end
    end

    def batch
      @batch = []
      yield
      b = @batch
      @batch = nil
      b.each do |mutation|
        send(*mutation)
      end
    ensure
      @batch = nil
    end

    def get(column_family, key, *columns_and_options)
      column_family, column, sub_column, options =
        extract_and_validate_params_for_real(column_family, [key], columns_and_options, READ_DEFAULTS)
      @data[column_family.to_sym] ||= OrderedHash.new
      if schema[column_family]['Type'] == 'Standard'
        get_standard(column_family, key, column, options)
      else
        get_super(column_family, key, column, sub_column, options)
      end
    end

    def get_standard(column_family, key, column, options)
      d = @data[column_family.to_sym][key] || OrderedHash.new
      if column
        d[column]
      else
        if options[:count]
          keys = d.keys.sort
          keys = keys.reverse if options[:reversed]
          keys = keys[0...options[:count]]
          keys.inject(OrderedHash.new) do |memo, key|
            memo[key] = d[key]
            memo
          end
        else
          d
        end
      end
    end

    def get_super(column_family, key, column, sub_column, options)
      if column
        if sub_column
          @data[column_family.to_sym][key] &&
          @data[column_family.to_sym][key][column] &&
          @data[column_family.to_sym][key][column][sub_column]
        else
          d = @data[column_family.to_sym][key] && @data[column_family.to_sym][key][column] ?
            @data[column_family.to_sym][key][column] :
            OrderedHash.new
          if options[:start] || options[:finish]
            start = to_compare_with_type(options[:start], column_family, false)
            finish = to_compare_with_type(options[:finish], column_family, false)
            ret = OrderedHash.new
            d.keys.sort.each do |key|
              if (key >= start || start.nil?) && (key <= finish || finish.nil?)
                ret[key] = d[key]
              end
            end
            d = ret
          end

          if options[:count]
            keys = d.keys.sort
            keys = keys.reverse if options[:reversed]
            keys = keys[0...options[:count]]
            keys.inject(OrderedHash.new) do |memo, key|
              memo[key] = d[key]
              memo
            end
          else
            d
          end
        end
      elsif @data[column_family.to_sym][key]
        @data[column_family.to_sym][key]
      else
        OrderedHash.new
      end
    end

    def exists?(column_family, key, column=nil)
      !!get(column_family, key, column)
    end

    def multi_get(column_family, keys)
      keys.inject(OrderedHash.new) do |hash, key|
        hash[key] = get(column_family, key) || OrderedHash.new
        hash
      end
    end

    def remove(column_family, key, column=nil, sub_column=nil)
      @data[column_family.to_sym] ||= OrderedHash.new
      if @batch
        @batch << [:remove, column_family, key, column]
      else
        if column
          if sub_column
            @data[column_family.to_sym][key][column].delete(sub_column)
          else
            @data[column_family.to_sym][key].delete(column)
          end
        else
          @data[column_family.to_sym].delete(key)
        end
      end
    end

    def get_columns(column_family, key, columns)
      d = get(column_family, key)
      columns.collect do |column|
        d[column]
      end
    end

    def clear_column_family!(column_family)
      @data[column_family.to_sym] = OrderedHash.new
    end

    def count_columns(column_family, key, column=nil)
      get(column_family, key, column).keys.length
    end

    def multi_get_columns(column_family, keys, columns)
      keys.inject(OrderedHash.new) do |hash, key|
        hash[key] = get_columns(column_family, key, columns) || OrderedHash.new
        hash
      end
    end

    def multi_count_columns(column_family, keys)
      keys.inject(OrderedHash.new) do |hash, key|
        hash[key] = count_columns(column_family, key) || 0
        hash
      end
    end

    def get_range(column_family, options = {})
      column_family, _, _, options = 
        extract_and_validate_params_for_real(column_family, "", [options], READ_DEFAULTS)
      _get_range(column_family, options[:start].to_s, options[:finish].to_s, options[:count]).keys
    end

    def count_range(column_family, options={})
      count = 0
      l = []
      start_key = ''
      while (l = get_range(column_family, options.merge(:count => 1000, :start => start_key))).size > 0
        count += l.size
        start_key = l.last.succ
      end
      count
    end

    def schema(load=true)
      if !load && !@schema
        []
      else
        @schema ||= schema_for_keyspace(@keyspace)
      end
    end

    private

    def _get_range(column_family, start, finish, count)
      ret = OrderedHash.new
      @data[column_family.to_sym].keys.sort.each do |key|
        break if ret.keys.size >= count
        if (key >= start || start == '') && (key <= finish || finish == '')
          ret[key] = @data[column_family.to_sym][key]
        end
      end
      ret
    end

    def schema_for_keyspace(keyspace)
      doc = read_storage_xml
      ret = {}
      doc.css("Keyspaces Keyspace[@Name='#{keyspace}']").css('ColumnFamily').each do |cf|
        ret[cf['Name']] = {}
        if cf['CompareSubcolumnsWith']
          ret[cf['Name']]['CompareSubcolumnsWith'] = 'org.apache.cassandra.db.marshal.' + cf['CompareSubcolumnsWith']
        end
        if cf['CompareWith']
          ret[cf['Name']]['CompareWith'] = 'org.apache.cassandra.db.marshal.' + cf['CompareWith']
        end
        if cf['ColumnType']
          ret[cf['Name']]['Type'] = 'Super'
        else
          ret[cf['Name']]['Type'] = 'Standard'
        end
      end
      ret
    end

    def read_storage_xml
      @doc ||= Nokogiri::XML(open(@storage_xml))
    end

    def extract_and_validate_params_for_real(column_family, keys, args, options)
      column_family, column, sub_column, options = extract_and_validate_params(column_family, keys, args, options)
      options[:start] = nil if options[:start] == ''
      options[:finish] = nil if options[:finish] == ''
      [column_family, to_compare_with_type(column, column_family), to_compare_with_type(sub_column, column_family, false), options]
    end

    def to_compare_with_type(column_name, column_family, standard=true)
      return column_name if column_name.nil?
      klass = if standard
        schema[column_family.to_s]["CompareWith"]
      else
        schema[column_family.to_s]["CompareSubcolumnsWith"]
      end

      case klass
      when "org.apache.cassandra.db.marshal.UTF8Type"
        column_name
      when "org.apache.cassandra.db.marshal.TimeUUIDType"
        UUID.new(column_name)
      when "org.apache.cassandra.db.marshal.LongType"
        Long.new(column_name)
      else
        p klass
        raise
      end
    end
  end
end