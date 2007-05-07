module JdbcSpec
  module PostgreSQL
    module Column
      def simplified_type(field_type)
        return :integer if field_type =~ /^serial/i 
        super
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

      def default_value(value)
        # Boolean types
        return "t" if value =~ /true/i
        return "f" if value =~ /false/i
        
        # Char/String/Bytea type values
        return $1 if value =~ /^'(.*)'::(bpchar|text|character varying|bytea)$/
        
        # Numeric values
        return value if value =~ /^-?[0-9]+(\.[0-9]*)?/
        
        # Fixed dates / timestamp
        return $1 if value =~ /^'(.+)'::(date|timestamp)/
        
        # Anything else is blank, some user type, or some function
        # and we can't know the value of that, so return nil.
        return nil
      end
    end

    def modify_types(tp)
      tp[:primary_key] = "serial primary key"
      tp[:string][:limit] = 255
      tp[:integer][:limit] = nil
      tp[:boolean][:limit] = nil
      tp
    end
    
    def default_sequence_name(table_name, pk = nil)
      default_pk, default_seq = pk_and_sequence_for(table_name)
      default_seq || "#{table_name}_#{pk || default_pk || 'id'}_seq"
    end

    # Find a table's primary key and sequence.
    def pk_and_sequence_for(table)
      # First try looking for a sequence with a dependency on the
      # given table's primary key.
        result = select(<<-end_sql, 'PK and serial sequence')[0]
          SELECT attr.attname AS nm, name.nspname AS nsp, seq.relname AS rel
          FROM pg_class      seq,
               pg_attribute  attr,
               pg_depend     dep,
               pg_namespace  name,
               pg_constraint cons
          WHERE seq.oid           = dep.objid
            AND seq.relnamespace  = name.oid
            AND seq.relkind       = 'S'
            AND attr.attrelid     = dep.refobjid
            AND attr.attnum       = dep.refobjsubid
            AND attr.attrelid     = cons.conrelid
            AND attr.attnum       = cons.conkey[1]
            AND cons.contype      = 'p'
            AND dep.refobjid      = '#{table}'::regclass
        end_sql

        if result.nil? or result.empty?
          # If that fails, try parsing the primary key's default value.
          # Support the 7.x and 8.0 nextval('foo'::text) as well as
          # the 8.1+ nextval('foo'::regclass).
          # TODO: assumes sequence is in same schema as table.
          result = select(<<-end_sql, 'PK and custom sequence')[0]
            SELECT attr.attname AS nm, name.nspname AS nsp, split_part(def.adsrc, '\\\'', 2) AS rel
            FROM pg_class       t
            JOIN pg_namespace   name ON (t.relnamespace = name.oid)
            JOIN pg_attribute   attr ON (t.oid = attrelid)
            JOIN pg_attrdef     def  ON (adrelid = attrelid AND adnum = attnum)
            JOIN pg_constraint  cons ON (conrelid = adrelid AND adnum = conkey[1])
            WHERE t.oid = '#{table}'::regclass
              AND cons.contype = 'p'
              AND def.adsrc ~* 'nextval'
          end_sql
        end
        # check for existence of . in sequence name as in public.foo_sequence.  if it does not exist, join the current namespace
        result['rel']['.'] ? [result['nm'], result['rel']] : [result['nm'], "#{result['nsp']}.#{result['rel']}"]
      rescue
        nil
      end

    def insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil) #:nodoc:
      execute(sql, name)
      table = sql.split(" ", 4)[2]
      id_value || last_insert_id(table, sequence_name || default_sequence_name(table, pk))
    end

    def last_insert_id(table, sequence_name)
      Integer(select_value("SELECT currval('#{sequence_name}')"))
    end

    def _execute(sql, name = nil)
      log_no_bench(sql, name) do
        case sql.strip
        when /^(select|show)/i:
          @connection.execute_query(sql)
        else
          @connection.execute_update(sql)
        end
      end
    end
    
    def quote(value, column = nil)
      if value.kind_of?(String) && column && column.type == :binary
        "'#{escape_bytea(value)}'"
      elsif column && column.type == :primary_key
        return value.to_s
      else
        super
      end
    end

    def quote_column_name(name)
      %("#{name}")
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end
    
    def add_column(table_name, column_name, type, options = {})
      execute("ALTER TABLE #{table_name} ADD #{column_name} #{type_to_sql(type, options[:limit])}")
      execute("ALTER TABLE #{table_name} ALTER #{column_name} SET NOT NULL") if options[:null] == false
      change_column_default(table_name, column_name, options[:default]) unless options[:default].nil?
    end

    def change_column(table_name, column_name, type, options = {}) #:nodoc:
      begin
        execute "ALTER TABLE #{table_name} ALTER  #{column_name} TYPE #{type_to_sql(type, options[:limit])}"
      rescue ActiveRecord::StatementInvalid
        # This is PG7, so we use a more arcane way of doing it.
        begin_db_transaction
        add_column(table_name, "#{column_name}_ar_tmp", type, options)
        execute "UPDATE #{table_name} SET #{column_name}_ar_tmp = CAST(#{column_name} AS #{type_to_sql(type, options[:limit])})"
        remove_column(table_name, column_name)
        rename_column(table_name, "#{column_name}_ar_tmp", column_name)
        commit_db_transaction
      end
      change_column_default(table_name, column_name, options[:default]) unless options[:default].nil?
    end      
    
    def change_column_default(table_name, column_name, default) #:nodoc:
      execute "ALTER TABLE #{table_name} ALTER COLUMN #{column_name} SET DEFAULT '#{default}'"
    end
      
    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{table_name} RENAME COLUMN #{column_name} TO #{new_column_name}"
    end
    
    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      return super unless type.to_s == 'integer'
      
      if limit.nil? || limit == 4
        'integer'
      elsif limit < 4
        'smallint'
      else
        'bigint'
      end
    end
  end  
end
