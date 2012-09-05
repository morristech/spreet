# encoding: utf-8
require 'pathname'
require 'duration'
require 'money'
require 'time'
require 'big_array'
require 'spreet/coordinates'

# Create class for  arrays
BigArray.new("Cells", 10, 3)

module Spreet

  module VERSION
    version = nil
    File.open(File.join(File.dirname(__FILE__), "..", "VERSION")) {|f| version = f.read.split('.')}
    MAJOR = version[0].to_i.freeze
    MINOR = version[1].to_i.freeze
    TINY  = version[2].to_i.freeze
    PATCH = TINY.freeze
    PRE   = version[3].freeze
    STRING = version.freeze
  end


  # Represents a cell in a sheet
  class Cell
    attr_reader :text, :value, :type, :sheet, :coordinates
    attr_accessor :annotation

    def initialize(sheet, *args)
      @sheet = sheet
      @coordinates = Coordinates.new(*args)
      self.value = nil
      @empty = true
      @covered = false # determine_covered
      @annotation = nil
    end

    def value=(val)
      if val.is_a?(Cell)
        @value = val.value
        @type = val.type
        self.text = val.text
        @empty = val.empty?
        @annotation = val.annotation
      else
        @value = val
        @type = determine_type
        self.text = val
        @empty = false
      end
    end

    def empty?
      @empty
    end
    
    def covered?
      @covered
    end

    def clear!
      self.value = nil
      @empty = true
    end

    def remove!
      @sheet.remove(self.coordinates)
    end

    def <=>(other_cell)
      self.coordinates <=> other_cell.coordinates
    end

    def text=(val)
      @text = val.to_s
    end

    def inspect
      "<#{self.coordinates}: #{self.text.inspect}#{'('+self.value.inspect+')' if self.text != self.value}>"
    end

    private

    
    def determine_type
      if value.is_a? Date or value.is_a? DateTime
        :date
      elsif value.is_a? Numeric # or percentage
        :float
      elsif value.is_a? Money
        :currency
      elsif value.is_a? Duration
        :time
      elsif value.is_a?(TrueClass) or value.is_a?(FalseClass)
        :boolean
      else # if value.is_a?(String)
        :string
      end
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
      @cells = {} # BigArray::Cells.new
      @bound = compute_bound
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
      @updated = true
    end

    def row(*args)
      options = {}
      options = args.delete_at(-1) if args[-1].is_a? Hash
      row = options[:row] || @current_row
      args.each_index do |index|
        self[index, row] = args[index]
      end
      next_row
    end

    def rows(index)
      row = []
      for i in 0..bound.x
        row[i] = self[i, index]
      end
      return row
    end

    def each_row(&block)
      for j in 0..bound.y
        yield rows(j)
      end
    end

    # Find or build cell
    def cell(*args)
      return c
    end
    
    def bound
      if @updated
        compute_bound
      else
        @bound
      end
    end

    def remove!(coordinates)
      raise ArgumentError.new("Must be a Coordinates") unless document.is_a?(Coordinates)
      @cells.delete(coordinates.to_i)
      @updated = true
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
      bound = Coordinates.new(0,0)
      for index, cell in @cells
      # for cell in @cells.compact
        unless cell.empty?
          bound.x = cell.coordinates.x if cell.coordinates.x > bound.x
          bound.y = cell.coordinates.y if cell.coordinates.y > bound.y
        end
      end
      @updated = false
      @bound = bound
      return @bound
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
      @array.delete_at(index(sheet))
    end

    def move(sheet, shift=0)
      position = index(sheet) + shift
      position = 0 if position < 0
      position = self.count-1 if position >= self.count
      move_at(sheet, position)
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
    @@handlers = {}
    @@associations = {}
    
    def initialize(option={})
      @sheets = Sheets.new(self)
    end

    def write(file, options={})
      handler = self.class.extract_handler(file, options.delete(:format))
      handler.write(self, file, options)
    end

    class << self
    
      def register_handler(klass, name, options={})
        if klass.respond_to?(:read) or klass.respond_to?(:write)
          if name.is_a?(Symbol)
            @@handlers[name] = klass # options.merge(:class=>klass)
          elsif
            raise ArgumentError.new("Name is invalid. Symbol expected, #{name.class.name} got.")
          end
        else
          raise ArgumentError.new("Handler do not support :read or :write method.")
        end
      end
      
      def read(file, options={})
        handler = extract_handler(file, options.delete(:format))
        return handler.read(file, options)
      end

      def extract_handler(file, handler_name=nil)
        file_path = Pathname.new(file)
        extension = file_path.extname.to_s[1..-1]
        if !handler_name and extension.size > 0
          handler_name = extension.to_sym
        end
        if @@handlers[handler_name]
          return @@handlers[handler_name]
        else
          raise ArgumentError.new("No corresponding handler (#{handler_name.inspect}). Available: #{@@handlers.keys.collect{|k| k.inspect}.join(', ')}.")
        end
      end

    end


  end  

end

require 'spreet/handlers'
