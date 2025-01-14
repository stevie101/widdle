module Widdle::Query
  class Select < Result
    attr :client
    def initialize(client, *params)
      @client = client
      args = ( params.pop if Hash === params.last ) || {}
      @columns               = args.delete(:select) if args.has_key? :select
      @indices               = args.delete(:from) if args.has_key?(:from)
      @match                 = args.delete(:match) if args.has_key?(:match)
      @wheres                = args.delete(:where) if args.has_key?(:where)
      @group_by              = args.delete(:group)
      @order_by              = args.delete(:order)
      @order_within_group_by = args.delete(:group_order)
      @offset                = args.delete(:offset)
      @limit                 = args.delete(:limit)
      @options               = args.delete(:options) || {}
#      client.logger.debug "Widdle::Query#select.init: client=#{@client} idx=#{@indices} cols=#{@columns}  wheres=#{@wheres}"
    end
  
    def columns(*cols)
      @columns += cols
      self
    end
    
    def columns
      @columns
    end
    
    def from(*indices)
      @indices += indices
      self
    end
  
    def match(*match)
      @match += match
      self
    end
  
    def where(*filters)
      @wheres += filters
      self
    end
  
    def group(attribute)
      @group_by = attribute
      self
    end
  
    def order(order)
      @order_by = order
      self
    end
  
    def group_order(order)
      @order_within_group_by = order
      self
    end
  
    # limit or [offset,limit]
    def limit(limit=20)
      @limit = Array.wrap(limit)
      self
    end
  
    def offset(offset)
      @offset = offset
      self
    end
  
    def with_options(options = {})
      @options.merge! options
      self
    end
  
    def to_s
      #FIXME validate everything to avoid injection
      sql = "SELECT #{columns_clause}"
      sql << " FROM #{ @indices.join(', ') }" if !@indices.nil?
      sql << " WHERE #{ combined_wheres }" if wheres?
      sql << " GROUP BY #{@group_by}"      if !@group_by.nil?
      sql << " ORDER BY #{@order_by}"      if !@order_by.nil?
      unless @order_within_group_by.nil?
        sql << " WITHIN GROUP ORDER BY #{@order_within_group_by}"
      end
      sql << limit_clause
      sql << " OFFSET #{@offset}" if !@offset.nil?
      sql << " #{options_clause}" unless @options.empty?
    
      sql
    end
  
    private
    
    def columns_clause
      if @columns
        cols = @columns.map {|c|
          if Hash === c
            c.map{|k,v| v == true ? "#{k}" : "#{v} as `#{k}`" }
          else
            c
          end
        }.flatten.reject(&:empty?)
        cols.push('*') if cols.empty?
        cols.join(', ')
      else
        cols = ['*']
      end
    end

    def wheres?
      @wheres || @match
    end
  
    def combined_wheres
      unless !@wheres
        @wheres.reject!(&:empty?)
        [ *@match.map{|v| "MATCH('#{client.escape(v)}')"}, where_clause(@wheres) ].reject(&:empty?).join(' AND ')
      end
    end
  
    # where: [ conditions ]
    # valid forms for conditions:
    #   String with bind values, e.g.: "attr != :val2 AND lat < :lat AND kid NOT IN :kidarray"
    #     bind values are drawn from hash which must be last entry of conditions array
    #   Hash of attributes and values: { attr1: val1, ... }
    #     and remaining keys in Hash not consumed by bind values are processed according to value type:
    #       Array, e.g. id: [1,2,3,4]  =>  id IN (1,2,3,4)
    #       Range, e.g. kine: 3.0..4.0 =>  kine BETWEEN 3.0 and 4.0
    #       numeric, e.g.  class_id: 4 =>  class_id = 4
    #       String with bind values, e.g.  lng: "> :lngval"    =>  lng > 2.8173   (where hash also contains key :lngval)
    def where_clause( conditions )
      #FIXME validate everything to avoid injection
      binds = conditions.last if Hash === conditions.last
      bound = []  # remember which binds we consumed from options hash
#      client.logger.debug "Widdle::Query:where_clause: #{conditions.inspect}"
      conditions.map{ |condition|
        if Hash === condition
          condition.map{|k,v|
            next if bound.include?(k)  # skip if previously consumed
            case v
            when Array
              vals = v.map{|val| client.escape(val) }
              "#{k} IN (#{vals.to_s[1..-2]})"
            when Range
              if v.exclude_end?
                "#{k} >= #{v.min} AND #{k} < #{v.max}"
              else
                "#{k} BETWEEN #{v.min} AND #{v.max}"
              end
            when Fixnum, Float
                "#{k} = #{v}"
            else
              "#{k} #{bind_symbols( v.to_s, binds, bound )}"
            end
          }
        else 
          bind_symbols( condition.to_s, binds, bound )
        end
      }.reject(&:empty?).join(' AND ')
    end
  
    def bind_symbols( s, binds, bound )
      s.gsub(/:([a-zA-Z]\w*)/) do
        match = $1.to_sym
        if binds.include?(match)
          bound << match
          client.escape(binds[match])
        else
          raise ArgumentError.new("missing value for :#{match} in #{s}")
        end
      end
    end
  
    def limit_clause
      
      if !@limit.nil?
      
        case @limit
        when Array        
          return " LIMIT #{@limit[0]},#{@limit[1]}"
        when Integer        
          return " LIMIT #{@limit}"
        end
        
      end
      
      return ""
      
    end
  
    def options_clause
      #FIXME  the keys and values need to be validated and filtered/escaped to prevent injection
      # preferrably in a way that doesn't require updating with each sphinx version
      # see http://sphinxsearch.com/docs/2.0.1/sphinxql-select.html
      # Supported options and respectively allowed values are:
      # 'ranker' - any of 'proximity_bm25', 'bm25', 'none', 'wordcount', 'proximity', 'matchany', or 'fieldmask'
      # 'max_matches' - integer (per-query max matches value)
      # 'cutoff' - integer (max found matches threshold)
      # 'max_query_time' - integer (max search time threshold, msec)
      # 'retry_count' - integer (distributed retries count)
      # 'retry_delay' - integer (distributed retry delay, msec)
      # 'field_weights' - a named integer list (per-field user weights for ranking)
      # 'index_weights' - a named integer list (per-index user weights for ranking)
      # 'reverse_scan' - 0 or 1, lets you control the order in which full-scan query processes the rows
      'OPTION ' + @options.map { |k,v| "#{k}=#{v}" }.join(', ')
    end
  end
end