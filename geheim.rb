#!/usr/bin/ruby

require "digest"
require "fileutils"
require "pp"
require "openssl"
require 'digest/sha2'
require 'base64'

$data_dir = "#{ENV['HOME']}/.geheimstore"
$export_dir = "#{ENV['HOME']}/.geheimexport"
$key_file = "#{ENV['HOME']}/.geheim.key"

module Git
  def initialize
    super()
    @wd = Dir.pwd
  end

  def git_add(file:)
    dirname, basename = File.dirname(file), File.basename(file)
    Dir.chdir(dirname)
    puts %x{git add "#{basename}"}
    #puts %x{git commit -m "Add #{file}"} if commit
    Dir.chdir(@wd)
  end

  def git_rm(file:)
    dirname, basename = File.dirname(file), File.basename(file)
    Dir.chdir(dirname)
    puts %x{git rm "#{basename}"}
    #puts %x{git commit -m "Remove #{file}"} if commit
    Dir.chdir(@wd)
  end

  def git_status
    Dir.chdir($data_dir)
    puts %x{git status}
    Dir.chdir(@wd)
  end

  def git_commit
    Dir.chdir($data_dir)
    puts %x{git commit -a -m 'Changing stuff, not telling what in commit history'}
    Dir.chdir(@wd)
  end

  def git_reset
    Dir.chdir($data_dir)
    puts %x{git reset --hard}
    Dir.chdir(@wd)
  end

  def git_sync
    puts "Synchronising #{$data_dir}"
    Dir.chdir($data_dir)
    puts %x{git pull origin master}
    puts %x{git push origin master}
    puts %x{git status}
    Dir.chdir(@wd)
  end
end

module Encryption
  @@alg = "AES-256-CBC"
  @@key = nil
  @@iv = nil

  def initialize
    super()
    if @@key.nil?
      @@key = File.read($key_file)
      if ENV['IV']
        input = ENV['IV']
      else
        print "IV: "
        input = $stdin.gets.chomp
      end
      iv = input * 2 + "Hello world" + input * 2
      @@iv = iv[0..15]
    end
  end

  def encrypt(plain:)
    aes = OpenSSL::Cipher::Cipher.new(@@alg)
    aes.encrypt
    aes.key = @@key
    aes.iv = @@iv

    encrypted = aes.update(plain)
    encrypted << aes.final

    encrypted
  end

  def decrypt(encrypted:)
    aes = OpenSSL::Cipher::Cipher.new(@@alg)
    aes.decrypt
    aes.key = @@key
    aes.iv = @@iv

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

class CommitFile
  include Git
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
    git_add(file: file)
  end
end

class GeheimData < CommitFile
  include Encryption
  include Git
  attr_accessor :data

  def initialize(data_file:, data: nil)
    super()

    @data_path = "#{$data_dir}/#{data_file}"
    if data.nil?
      @data = decrypt(encrypted: File.read(@data_path))
    else
      @data = data
    end
  end

  def to_s
    "\t#{@data.gsub("\n", "\n\t")}\n"
  end

  def rm
    puts "Deleting #{@data_path}"
    git_rm(file: @data_path)
  end

  def export(destination_file:)
    unless File.directory?($export_dir)
      puts "Creating #{$export_dir}"
      FileUtils.mkdir_p($export_dir)
    end

    destination_path = "#{$export_dir}/#{destination_file}"
    puts "Exporting to #{destination_path}"

    File.open(destination_path, "w") do |fd|
      fd.write(@data)
    end
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
    @index_path = "#{$data_dir}/#{index_file}"
    @hash = File.basename(index_file).sub(".index", "")

    if description.nil?
      @description = decrypt(encrypted: File.read(@index_path))
    else
      @description = description
    end
  end

  def is_binary?
    if @description.include?(".txt")
      false
    else
      @description.include?(".")
    end
  end

  def get_data(data: nil)
    GeheimData.new(data_file: @data_file, data: data)
  end

  def to_s
    binary = is_binary? ? "(BINARY) " : ""
    "#{@description} #{binary}...#{@hash[-11...-1]}\n"
  end

  def <=>(other)
    @description <=> other.description
  end

  def rm
    puts "Deleting #{@index_path}"
    git_rm(file: @index_path)
  end

  def commit
    commit_content(file: @index_path, content: encrypt(plain: @description))
  end
end

class Geheim
  def initialize
    super()

    unless File.directory?($data_dir)
      puts "Creating #{$data_dir}"
      FileUtils.mkdir_p($data_dir)
    end
  end

  def ls(search_term: nil, show: false, export: false)
    indexes = Array.new
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      print index
      if show and !index.is_binary?
        print index.get_data
      elsif export
        index.get_data.export(destination_file: File.basename(index.description))
      end
    end
  end

  def import_recursive(directory:)
    Dir.glob("#{directory}/**/*").each do |source_file|
      next if File.directory?(source_file)
      file = source_file.sub("#{directory}/", "")
      add(description: file, file: source_file)
    end
  end

  def add(description:, file: nil)
    hash = hash_path(description)

    if file.nil?
      print "Data: "
      data = $stdin.gets.chomp
    elsif !File.exists?(file)
      puts "ERROR: #{file} does not exist!"
      exit(3)
    else
      puts "Importing #{file}"
      data = File.read(file)
    end

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
    Dir.glob("#{$data_dir}/**/*.index").each do |index_file|
      index = Index.new(index_file: index_file.sub($data_dir, ""))
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

class CLI
  include Git

  def initialize(interactive: false)
    super()
    @interactive = interactive
  end

  def help
    puts <<-END
      ls
      SEARCHTERM
      show SEARCHTERM
      add DESCRIPTION
      import FILE
      import_r DIRECTORY
      rm SEARCHTERM
      sync|status|commit|reset
      help
      shell
    END
  end

  def shell_loop(argv)
    loop do
      geheim = Geheim.new
      action = argv[0]
      case action
      when 'ls'
        geheim.ls
      when 'show'
        geheim.ls(search_term: argv[1], show: true)
      when 'export'
        geheim.ls(search_term: argv[1], export: true)
      when 'add'
        geheim.add(description: argv[1])
      when 'import'
        geheim.add(file: argv[1])
      when 'import_r'
        geheim.import_recursive(directory: argv[1])
      when 'rm'
        geheim.rm(search_term: argv[1])
      when 'help'
        help
      when 'shell'
        @interactive = true
        puts "Switching to interactive mode"
      when 'exit'
        @interactive = false
        puts "Good bye"
      when 'status'
        git_status
      when 'commit'
        git_commit
      when 'reset'
        git_reset
      when 'sync'
        git_sync
      else
        geheim.ls(search_term: action)
      end

      break unless @interactive
      print "% "
      argv = $stdin.gets.chomp.split(" ")
    end
  end
end

begin
  cli = CLI.new
  cli.shell_loop(ARGV)
end
