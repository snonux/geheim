#!/usr/bin/ruby

require "digest"
require "fileutils"
require "pp"
require "openssl"
require 'digest/sha2'
require 'base64'

module Encryption
  def initialize
    super()
    key_file = "../.geheim.key"
    iv_file = "../.geheim.iv"
    @@alg = "AES-256-CBC"
    @key = Base64.encode64(File.read(key_file))
    @iv = File.read(iv_file)
  end

  def encrypt(plain:)
    aes = OpenSSL::Cipher::Cipher.new(@@alg)
    aes.encrypt
    aes.key = @key
    aes.iv = @iv

    encrypted = aes.update(plain)
    encrypted << aes.final

    encrypted
  end

  def decrypt(encrypted:)
    aes = OpenSSL::Cipher::Cipher.new(@@alg)
    aes.decrypt
    aes.key = @key
    aes.iv = @iv

    plain = aes.update(encrypted)
    plain << aes.final

    plain
  end

  def test
    plain_input = "foo bar baz"
    encrypted = encrypt(plain: plain_input)
    plain = decrypt(encrypted: encrypted)
    pp plain == plain_input
  end
end

class Config
  def initialize
    # Nice example/reference: https://gist.github.com/byu/99651
    @@data_dir = "./data"
  end
end

class CommitFile < Config
  def initialize
    super()
  end

  def commit_content(file:, content:, update: false)
    if File.exists?(file) and !update
      puts "ERROR: #{file} already exists"
      exit(3)
    end

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
  include Encryption
  attr_accessor :data

  def initialize(data_file:, data: nil)
    super()

    @data_path = "#{@@data_dir}/#{data_file}"
    if data.nil?
      @data = decrypt(encrypted: File.read(@data_path))
    else
      @data = data
    end
  end

  def to_s
    "#{@data}\n"
  end

  def rm
    puts "Deleting #{@data_path}"
    File.unlink(@data_path)
  end

  def commit
    commit_content(file: @data_path, content: encrypt(plain: @data))
  end
end

class Index < CommitFile
  include Encryption
  attr_accessor :description, :data_file

  def initialize(index_file:, description: nil)
    super()
    @data_file = index_file.sub(".index", ".data")
    @index_path = "#{@@data_dir}/#{index_file}"
    @hash = File.basename(index_file).sub(".index", "")

    if description.nil?
      @description = decrypt(encrypted: File.read(@index_path))
    else
      @description = description
    end
  end

  def get_data(data: nil)
    GeheimData.new(data_file: @data_file, data: data)
  end

  def to_s
    "=> #{@description} <= ...#{@hash[-11...-1]}\n"
  end

  def <=>(other)
    @description <=> other.description
  end

  def rm
    puts "Deleting #{@index_path}"
    File.unlink(@index_path)
  end

  def commit
    commit_content(file: @index_path, content: encrypt(plain: @description))
  end
end

class Geheim < Config
  def initialize
    super()

    unless File.directory?(@@data_dir)
      puts "Creating #{@@data_dir}"
      FileUtils.mkdir_p(@@data_dir)
    end
  end

  def ls(search_term: nil, show: false)
    indexes = Array.new
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      print index
      print index.get_data if show
    end
  end

  def add(description:)
    hash = hash_path(description)

    print "Data: "
    data = $stdin.gets.chomp

    index = Index.new(index_file: "#{hash}.index", description: description)
    data = index.get_data(data: data)

    data.commit
    index.commit
  end

  def rm(search_term:)
    indexes = Array.new
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      loop do
        print index
        print "You really want to delete this? (y/n): "
        case $stdin.gets.chomp
        when 'y'
          data = index.get_data
          data.rm
          index.rm
          break
        when 'n'
          break
        end
      end
    end
  end

  private def walk_indexes(search_term:)
    Dir.glob("#{@@data_dir}/**/*.index").each do |index_file|
      index = Index.new(index_file: index_file.sub(@@data_dir, ""))
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

  def help
    puts <<-END
        geheim ls
        geheim SEARCHTERM
        geheim show SEARCHTERM
        geheim add DESCRIPTION
        geheim rm SEARCHTERM
        geheim help
    END
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
  when 'rm'
    geheim.rm(search_term: ARGV[1])
  when 'help'
    geheim.help
  else
    geheim.ls(search_term: action)
  end
end
