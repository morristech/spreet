# encoding: utf-8
require 'csv'

module Spreet
  # Universal CSV support
  CSV = (::CSV.const_defined?(:Reader) ? ::FasterCSV : ::CSV).freeze

  class Coordinates
    # Limit coordinates x and y in 0..65535 but coordinates are in one integer of 32 bits
    CPU_SEMI_WIDTH = 16 # ((RUBY_PLATFORM.match(/^[^\-]*[^\-0-9]64/) ? 64 : 32) / 2).freeze
    Y_FILTER = ((1 << CPU_SEMI_WIDTH) - 1).freeze

    BASE_26_BEF = "0123456789abcdefghijklmnop"
    BASE_26_AFT = "abcdefghijklmnopqrstuvwxyz"

    attr_accessor :x, :y
    def initialize(*args)
      value = (args.size == 1 ? args[0] : args)
      @x, @y = 0, 0
      if value.is_a? String
        if value.downcase.match(/^[a-z]+[0-9]+$/)
          value = value.downcase.split(/([A-Z]+|[0-9]+)/).delete_if{|x| x.size.zero?}
          @x, @y = value[0].tr(BASE_26_AFT, BASE_26_BEF).to_i(26), value[1].to_i(10)-1
        elsif value.downcase.match(/^[0-9]+[^0-9]+[0-9]+$/)
          value = value.downcase.split(/[^0-9]+/)
          @x, @y = value[0].to_i(10), value[1].to_i(10)
        end
      elsif value.is_a? Integer
        @x, @y = (value >> CPU_SEMI_WIDTH), value & Y_FILTER
      elsif value.is_a? Coordinates
        @x, @y = value.x, value.y
      elsif value.is_a? Array
        @x, @y = value[0].to_i, value[1].to_i
      elsif value.is_a? Hash
        @x, @y = value[:x] || value[:column] || 0, value[:y] || value[:row] || 0
      end
    end

    def to_s
      @x.to_s(26).tr(BASE_26_BEF, BASE_26_AFT).upcase+(@y+1).to_s(10)
    end

    def to_a
      [@x, @y]
    end

    def to_hash
      {:x=>@x, :y=>@y}
    end
    
    def to_i
      (@x << CPU_SEMI_WIDTH) + @y
    end

    def ==(other_coordinate)
      other_coordinate.x == self.x and other_coordinate.y == self.y
    end

    def <=>(other_coordinate)
      self.to_i <=> other_coordinate.to_i
    end
  end

  # Represents a cell in a sheet
  class Cell
    attr_reader :text, :value, :sheet, :coordinates

    def initialize(sheet, *args)
      @sheet = sheet
      @coordinates = Coordinates.new(*args)
      value = nil
      @empty = true
    end

    def value=(val)
      @value = val
      @text = val.to_s
      @empty = false
    end

    def empty?
      @empty
    end

    def clear
      value = nil
      @empty = true
    end

    def remove!
      @sheet.remove(self.coordinates)
    end

    def <=>(other_cell)
      self.coordinates <=> other_cell.coordinates
    end

  end

  class Sheet
    attr_reader :document, :name, :columns
    attr_accessor :current_row

    def initialize(document, name=nil)
      @document = document
      self.name = name
      raise ArgumentError.new("Must be a Document") unless document.is_a? Document
      @current_row = 0
      @cells = {}
    end

    def name=(value)
      unless value
        value = (@document.sheets.count > 0 ? @document.sheets[-1].name.succ : "Sheet 1")
      end 
      raise ArgumentError.new("Name of sheet must be given") if value.to_s.strip.size.zero?
      if @document.sheets[value]
        raise ArgumentError.new("Name of sheet must be unique")
      end
      @name = value
    end

    def cells
      @cells.delete_if{|k,v| v.empty?}
      @cells.values
    end

    def next_row(increment = 1)
      @current_row += increment
    end
    
    def previous_row(increment = 1)
      @current_row -= increment
    end

    def [](*args)
      coord = Coordinates.new(*args)
      @cells[coord.to_i] ||= Cell.new(self, coord)
      return @cells[coord.to_i]
    end

    def []=(*args)
      value = args.delete_at(-1)
      cell = self[*args]
      cell.value = value
    end

    def row(*args)
      options = args.delete_at(-1) if args[-1].is_a? Hash
      row = options[:row] || @current_row
      args.each_index do |index|
        @cells[index, row] = args[index]
      end
      next_row
    end

    # Find or build cell
    def cell(*args)
      return c
    end
    
    def bound
      @bound
    end

    def remove!(coordinates)
      raise ArgumentError.new("Must be a Coordinates") unless document.is_a?(Coordinates)
      @cells.delete(coordinates.to_i)
      @bound = compute_bound
    end

    # Moves the sheet to an other position in the list of sheets
    def move_to(position)
      @document.sheets.move_at(self, position)
    end

    # Moves the sheet higher in the list of sheets
    def move_higher(increment=1)
      @document.sheets.move(self, increment)
    end

    # Moves the sheet lower in the list of sheets
    def move_lower(increment=1)
      @document.sheets.move(self, -increment)
    end

    private

    def compute_bound
      bound = Coordinates.new
      for cell in @cells
        unless cell.empty?
          bound.x = cell.coordinates.x if cell.coordinates.x > bound.x
          bound.y = cell.coordinates.y if cell.coordinates.x > bound.y
        end
      end
      return bound
    end

  end


  class Sheets

    def initialize(document)
      raise ArgumentError.new("Must be a Document") unless document.is_a?(Document)
      @document = document
      @array = []
    end

    def count
      @array.size
    end

    def index(name_or_sheet)
      if name_or_sheet.is_a? String
        @array.each_index do |i|
          return i if @array[i].name == name_or_sheet
        end
      elsif name_or_sheet.is_a? Integer
        return (@array[name_or_sheet].nil? ? nil : name_or_sheet)
      else
        return @array.index(name_or_sheet)
      end
    end

    def add(name=nil, position=-1)
      sheet = Sheet.new(@document, name)
      @array.insert(position, sheet)
      return sheet
    end

    def [](sheet)
      sheet = index(sheet)
      return (sheet.is_a?(Integer) ? @array[sheet] : nil)
    end

    def remove(sheet)
      @array.delete(sheet)
    end

    def move(sheet, shift=0)
      move_at(sheet, index(sheet) + shift)
    end

    def move_at(sheet, position=-1)
      if i = index(sheet)
        @array.insert(position, @array.delete_at(i))
      end
    end

    def each(&block)
      for item in @array
        yield item
      end
    end

  end


  class Document
    attr_reader :sheets
    @@formats = {}
    @@associations = {}
    
    def initialize(option={})
      @sheets = Sheets.new(self)
    end
    
    def to_term
      text = "Spreet (#{@sheets.count}):\n"
      for sheet in @sheets
        text << " - #{sheet.name}:\n"
        for cell in sheet.cells.sort
          text << "   - #{cell.coordinates.to_s}: #{cell.text.inspect}\n"
        end
      end
      return text
    end

    class << self
    
      def register_format(klass, name, options={})
        if klass.respond_to?(:read) or klass.respond_to?(:write)
          if name.is_a?(Symbol)
            @@formats[name] = options.merge(:class=>klass)
          elsif
            raise ArgumentError.new("Name is invalid. Symbol expected, #{name.class.name} got.")
          end
        else
          raise ArgumentError.new("Format do not support :read or :write method.")
        end
      end
      
      def read(file, options={})
        file_path = Pathname.new(file)
        format = nil
        if options[:format]
          format = @@formats[options.delete(:format)]
        else
          for formater in @@formats
            # if formater.respond_to? :
          end
        end
      end
      
      def write(file, options={})
      end
    end


  end  

end