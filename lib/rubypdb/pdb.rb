require 'bit-struct'
require 'enumerator'
require 'yaml'

module PDB
end

# Higher-level interface to PDB::StandardAppInfoBlock
class PDB::AppInfo
  attr_accessor :struct, :standard_appinfo, :data
  attr_reader :categories

  def initialize(standard_appinfo, pdb, *rest)
    @standard_appinfo = standard_appinfo
    @pdb = pdb
    data = rest.first

    unless data.nil?
      load(data)
    end
  end

  def load(data)
    if @standard_appinfo == true
      # Using standard app info block
      @data = PDB::StandardAppInfoBlock.new(data)

      # Define better structures for categories.
      # It's a list, of length 16.
      # At each position, there's a one-element hash. of name and id.
      @categories = []
      16.times do |i|
        @categories[i] = { 'name' => @data.send("category_name[#{i}]"),
                           'id' => @data.send("category_id[#{i}]") }
      end

      appinfo_struct_class_name = self.class.name + "::Struct"
      begin
       appinfo_struct_class = Kernel.const_get_from_string(appinfo_struct_class_name)
      rescue NameError
        puts appinfo_struct_class_name + " does not exist."
      end

      unless appinfo_struct_class.nil? or appinfo_struct_class == Struct
        @struct = appinfo_struct_class.new(@data.rest)
      end
    else
      # Not using standard app info block.
      # In this case, this function should be overwritten by subclass.
      @data = data
    end
  end

  # If val is an integer, find the string for the category at that index.
  # If it's a string, return the index of the category with that name.
  def category(val)
    if val.is_a? Integer
      return @categories[val]['name']
    else
      found = nil
      @categories.each_with_index do |c, i|
        if c['name'] == val
          found = i
          break
        end
      end

      return found
    end
  end

  def new_category(name)
    puts "Making new category called #{name}"
  end

  def dump()
    unless @struct.nil?
      if @standard_appinfo == true
        @data.rest = @struct.to_s
      end
      return @data.to_s
    else
      return @data
    end
  end

  def length()
    unless @struct.nil?
      if @standard_appinfo == true
         @data.rest = @struct.to_s
      end
      return @data.length
    else
      return @data.length
    end
  end

end

# This is a high-level interface to PDB::Resource / PDB::Record
# PDB::RecordAttributes, and the data of the record/resource
class PDB::Data
  attr_accessor :struct, :metadata

  def initialize(pdb, metadata, *rest)
    @pdb = pdb
    @metadata = metadata
    record = rest.first

    unless record.nil?
      load(record)
    end
  end

  def pdb=(p)
    @pdb = p
  end

  def load(data)
    format_class_name = self.class.name + "::Struct"
    begin
      format_class = Kernel.const_get_from_string(format_class_name)
    rescue NameError
      # puts format_class_name + " does not exist."
    end

    # puts "Format class: #{format_class}"
    unless format_class.nil? or format_class == Struct
      @struct = format_class.new(data)
    end

    @data = data
  end


  def dump()
    unless @struct.nil?
      return @struct.to_s
    else
      return @data
    end
  end

  def length()
    unless @struct.nil?
      return @struct.length()
    else
      return @data.length
    end
  end

  def category()
    cat = @metadata.attributes.category
    @pdb.appinfo.category(cat)
  end

  def category=(val)
    cat = @pdb.appinfo.category(val) # || @pdb.appinfo.new_category(val)
    attr = PDB::RecordAttributes.new(@metadata.attributes)
    attr.category = cat
    @metadata.attributes = attr
  end
end

class PalmPDB
  attr_reader :records, :index
  attr_accessor :header, :appinfo, :sortinfo
  include Enumerable

  def initialize()
    @index = []
    @records = {}
    @appinfo = nil
    @sortinfo = nil
    @header = PDB::Header.new()
  end

  def load(f)
    f.seek(0, IO::SEEK_END)
    @eof_pos = f.pos
    f.pos = 0  # return to beginning of file

    header_size = PDB::Header.round_byte_length  # 78
    header_data = f.read(header_size)
    @header = PDB::Header.new(header_data)   # Read the header.

    # Next comes metadata for resources or records...
    resource_size = PDB::Resource.round_byte_length
    record_size = PDB::Record.round_byte_length

    @header.resource_index.number_of_records.times do |i|
      if @header.attributes.resource == 1
        @index << PDB::Resource.new(f.read(resource_size))
      else
        @index << PDB::Record.new(f.read(record_size))
      end
    end

    # Now, a sanity check...
    # Each entry in the index should have a unique offset.
    # Which means, the number of unique offsets == number of things in the index
    unless @index.collect {|i| i.offset }.uniq.length == @index.length
      puts "Eeek.  Multiple records share an offset!"
    end
    # And just to be sure they're in a sensible order...
    @index = @index.sort_by {|i| i.offset }

    # The order of things following the headers:
    #   1- Appinfo, Sortinfo, Records
    #   2 - Appinfo, Records
    #   3 - Sortinfo, Records
    #   4 - Records
    #
    # Unfortunately, it's not necessarily clear what the length of any of these
    # are ahead of time, so it needs to be calculated.

    appinfo_length = 0
    sortinfo_length = 0
    if @header.appinfo_offset > 0
      if @header.sortinfo_offset > 0
        appinfo_length = @header.sortinfo_offset - @header.appinfo_offset  # 1
        sortinfo_length = @index.first.offset - @header.sortinfo_offset
      else
        appinfo_length = @index.first.offset - @header.appinfo_offset      # 2
      end
    elsif @header.sortinfo_offset > 0
      sortinfo_length = @index.first.offset - @header.sortinfo_offset      # 3
    end

    if appinfo_length > 0
      f.pos = @header.appinfo_offset
      @appinfo_data = f.read(appinfo_length)
      appinfo_class_name = self.class.name + "::AppInfo"
      
      begin
        appinfo_class = Kernel.const_get_from_string(appinfo_class_name)
      rescue NameError
        puts appinfo_class_name + " does not exist."
      end

      unless appinfo_class.nil?
        @appinfo = appinfo_class.new(self, @appinfo_data)
      else
        @appinfo = nil
      end
    end

    if sortinfo_length > 0
      f.pos = @header.sortinfo_offset
      @sortinfo_data = f.read(sortinfo_length)

      sortinfo_class_name = self.class.name + "::SortInfo"
      
      begin
        sortinfo_class = Kernel.const_get_from_string(sortinfo_class_name)
      rescue NameError
        puts sortinfo_class_name + " does not exist."
      end

      unless sortinfo_class.nil?
        @sortinfo = sortinfo_class.new(@sortinfo_data)
      else
        @sortinfo = nil
      end
    end

    if @header.attributes.resource == 1  # Is it a resource, or a record?
      data_class_name = self.class.name + "::Resource"
    else
      data_class_name = self.class.name + "::Record"
    end

    data_class = PDB::Data
    begin
      data_class = Kernel.const_get_from_string(data_class_name)
    rescue
    end

    i = 0
    @index.each_cons(2) do |curr, nxt|
      length = nxt.offset - curr.offset  # Find the length to the next record
      f.pos = curr.offset
      data = f.read(length)
      @records[curr.r_id] = data_class.new(self, curr, data)
      i = i + 1 
    end
    # ... And then the last one.
    entry = @index.last
    f.pos = entry.offset
    data = f.read()  # Read to the end
    @records[entry.r_id] = data_class.new(self, entry, data)
  end

  def each(&block)
    @records.each_pair {|k, record|
      yield(record)
    }
  end

  def ctime()
    Time.from_palm(@header.ctime)
  end

  def ctime=(t)
    @header.ctime = t.to_palm
  end

  def mtime()
    Time.from_palm(@header.mtime)
  end

  def mtime=(t)
    @header.mtime = t.to_palm
  end

  def backup_time()
    Time.from_palm(@header.baktime)
  end

  def backup_time=(t)
    @header.baktime = t.to_palm
  end
  
  # This should be done before dumping or doing a deeper serialization.
  def recompute_offsets()
    @header.resource_index.number_of_records = @records.length
    @header.resource_index.next_index = 0 # TODO: How is this determined?

    curr_offset = PDB::Header.round_byte_length

    # Compute length of index...
    unless @index == []
      @index.each do |i|
        curr_offset += i.length()
      end
    end

    unless @appinfo.nil?
      @header.appinfo_offset = curr_offset
      curr_offset += @appinfo.length()
    end

    unless @sortinfo.nil?
      @header.sortinfo_offset = curr_offset
      curr_offset += @sortinfo.length()
    end

    ## And here's the mysterious two-byte filler.
    #curr_offset += 2

    unless @index.length == 0
      @index.each do |i|
        rec = @records[i.r_id]
        i.offset = curr_offset
        curr_offset += rec.length
      end
    end
  end

  def dump(f)
    recompute_offsets()
    f.write(@header)

    @index.each do |i|
      f.write(i)
    end

    unless @appinfo.nil?
      f.write(@appinfo.dump())
    end

    unless @sortinfo.nil?
      f.write(@sortinfo.dump())
    end

    @index.each do |i|
      record = @records[i.r_id]
      f.write(record.dump())
    end
  end

  # Add a PDB::Data to the PDB
  def <<(datum)
    datum.pdb = self
    # Needs to be added to @index...
    # And to @records...
  end

end
