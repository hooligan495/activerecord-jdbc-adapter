module JdbcSpec
  module HSQLDB
    module Column
      def type_cast(value)
        return nil if value.nil? || value =~ /^\s*null\s*$/i
        case type
        when :string    then value
        when :integer   then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :primary_key then defined?(value.to_i) ? value.to_i : (value ? 1 : 0)
        when :float     then value.to_f
        when :datetime  then cast_to_date_or_time(value)
        when :timestamp then cast_to_time(value)
        when :binary    then value.scan(/[0-9A-Fa-f]{2}/).collect {|v| v.to_i(16)}.pack("C*")
        when :time      then cast_to_time(value)
        else value
        end
      end
      def cast_to_date_or_time(value)
        return value if value.is_a? Date
        return nil if value.blank?
        guess_date_or_time (value.is_a? Time) ? value : cast_to_time(value)
      end

      def cast_to_time(value)
        return value if value.is_a? Time
        time_array = ParseDate.parsedate value
        time_array[0] ||= 2000; time_array[1] ||= 1; time_array[2] ||= 1;
        Time.send(ActiveRecord::Base.default_timezone, *time_array) rescue nil
      end

      def guess_date_or_time(value)
        (value.hour == 0 and value.min == 0 and value.sec == 0) ?
        Date.new(value.year, value.month, value.day) : value
      end


      private
      def simplified_type(field_type)
        case field_type
        when /longvarchar/i
          :text
        else
          super(field_type)
        end
      end

      # Override of ActiveRecord::ConnectionAdapters::Column
      def extract_limit(sql_type)
        # HSQLDB appears to return "LONGVARCHAR(0)" for :text columns, which
        # for AR purposes should be interpreted as "no limit"
        return nil if sql_type =~ /\(0\)/
        super
      end
    end

    def modify_types(tp)
      tp[:primary_key] = "INTEGER GENERATED BY DEFAULT AS IDENTITY(START WITH 0) PRIMARY KEY"
      tp[:integer][:limit] = nil
      tp[:boolean][:limit] = nil
      # set text and float limits so we don't see odd scales tacked on
      # in migrations
      tp[:text][:limit] = nil
      tp[:float][:limit] = 17
      tp[:string][:limit] = 255
      tp[:datetime] = { :name => "DATETIME" }
      tp[:timestamp] = { :name => "DATETIME" }
      tp[:time] = { :name => "DATETIME" }
      tp[:date] = { :name => "DATETIME" }
      tp
    end

    def quote(value, column = nil) # :nodoc:
      case value
      when String
        if column && column.type == :binary
          "'#{quote_string(value).unpack("C*").collect {|v| v.to_s(16)}.join}'"
        else
          "'#{quote_string(value)}'"
        end
      else super
      end
    end

    def quote_string(str)
      str.gsub(/'/, "''")
    end

    def quoted_true
      '1'
    end

    def quoted_false
      '0'
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} #{type_to_sql(type, options[:limit])}"
    end

    def change_column_default(table_name, column_name, default) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DEFAULT #{quote(default)}"
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} RENAME TO #{new_column_name}"
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end

    def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil) #:nodoc:
      execute(sql, name)
      table = sql.split(" ", 4)[2]
      id_value || last_insert_id(table, nil)
    end

    def last_insert_id(table, sequence_name)
      Integer(select_value("SELECT IDENTITY() FROM #{table}"))
    end

    def add_limit_offset!(sql, options) #:nodoc:
      offset = options[:offset] || 0
      bef = sql[7..-1]
      if limit = options[:limit]
        sql.replace "select limit #{offset} #{limit} #{bef}"
      elsif offset > 0
        sql.replace "select limit #{offset} 0 #{bef}"
      end
    end

    # override to filter out system tables that otherwise end
    # up in db/schema.rb during migrations.  JdbcConnection#tables
    # now takes an optional block filter so we can screen out
    # rows corresponding to system tables.  HSQLDB names its
    # system tables SYSTEM.*, but H2 seems to name them without
    # any kind of convention
    def tables
      @connection.tables do |result_row|
        result_row.get_string(ActiveRecord::ConnectionAdapters::Jdbc::TableMetaData::TABLE_TYPE) !~ /^SYSTEM TABLE$/i
      end
    end

    # For migrations, exclude the primary key index as recommended
    # by the HSQLDB docs.  This is not a great test for primary key
    # index.
    def indexes(table_name, name = nil)
      @connection.indexes(table_name.to_s)
    end

  end
end
