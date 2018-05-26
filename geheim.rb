#!/usr/bin/ruby

require "digest"
require "fileutils"
require "pp"

class Config
  def initialize
    @data_dir = "./data"
    @key = "../.geheim.key"
  end
end

class CommitFile < Config
  def initialize
    super()
  end

  def commit_content(file:, content:)
    dirname = File.dirname(file)
    unless File.directory?(dirname)
      puts "Creating #{dirname}"
      FileUtils.mkdir_p(dirname)
    end

    puts "Writing #{file}"
    File.open(file, "w") do |fd|
      fd.write(content)
    end
  end
end

class GeheimData < CommitFile
  attr_accessor :data

  def initialize(data_file:, data: nil)
    super()

    @data_file = "#{@data_dir}/#{File.basename(data_file)}"
    if data.nil?
      @data = File.read(@data_file)
    else
      @data = data
    end
  end

  def to_s
    "#{@data}\n"
  end

  def commit
    commit_content(file: @data_file, content: @data)
  end
end

class Index < CommitFile
  attr_accessor :description, :data_file

  def initialize(index_file:, description: nil)
    super()

    @index_file = Dir.glob("#{@data_dir}/**/#{index_file}").first
    @data_file = @index_file.sub(".index", ".data")
    @hash = File.basename(@index_file).sub(".index", "")

    if description.nil?
      @description = File.open(@index_file, "r").readline.chomp
    else
      @description = description
    end
  end

  def to_s
    "=> #{@description} <= ...#{@hash[-11...-1]}\n"
  end

  def <=>(other)
    @description <=> other.description
  end

  def commit
    commit_content(file: @index_file, content: @description)
  end
end

class Geheim < Config
  def initialize
    super()

    unless File.directory?(@data_dir)
      puts "Creating #{@data_dir}"
      FileUtils.mkdir_p(@data_dir)
    end
  end

  def ls(search_term: nil, show: false)
    indexes = Array.new
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      print index
      print GeheimData.new(data_file: index.data_file) if show
    end
  end

  def add(description:)
    hash = hash_path(description)

    print "Data: "
    data = $stdin.gets.chomp

    data = GeheimData.new(data_file: "#{hash}.data", data: data)
    index = Index.new(index_file: "#{hash}.index", description: description)

    data.commit
    index.commit
  end

  private def walk_indexes(search_term:)
    Dir.glob("#{@data_dir}/**/*.index").each do |index_file|
      index = Index.new(index_file: File.basename(index_file))
      if search_term.nil? or index.description.include?(search_term)
        yield index
      end
    end
  end

  private def hash_path(path_string)
    path = Array.new
    path_string.split("/").each do |part|
        path << Digest::SHA256.hexdigest(part)
    end
    path.join("/")
  end
end

begin
  action = ARGV[0]
  geheim = Geheim.new

  case action
  when 'ls'
    geheim.ls
  when 'show'
    geheim.ls(search_term: ARGV[1], show: true)
  when 'add'
    geheim.add(description: ARGV[1])
  else
    geheim.ls(search_term: action)
  end
end
