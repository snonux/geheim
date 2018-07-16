#!/usr/bin/ruby

require "digest"
require "fileutils"
require "pp"
require "openssl"
require "digest/sha2"
require "base64"
require "io/console"

$data_dir = "#{ENV['HOME']}/.geheimstore"
$export_dir = "#{ENV['HOME']}/.geheimexport"
$key_file = "#{ENV['HOME']}/.geheim.key"
$edit_cmd = "vim --cmd 'set noswapfile' --cmd 'set nobackup' --cmd 'set nowritebackup'"

module Git
  def initialize
    super()
    @wd = Dir.pwd
  end

  def git_add(file:)
    dirname, basename = File.dirname(file), File.basename(file)
    Dir.chdir(dirname)
    puts %x{git add "#{basename}"}
    Dir.chdir(@wd)
  end

  def git_rm(file:)
    dirname, basename = File.dirname(file), File.basename(file)
    Dir.chdir(dirname)
    puts %x{git rm "#{basename}"}
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
      if ENV['PIN']
        input = ENV['PIN']
      else
        print "PIN: "
        input = STDIN.noecho(&:gets).chomp
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

  def commit_content(file:, content:, force: false)
    if File.exists?(file) and !force
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
  attr_accessor :exported_path

  def initialize(data_file:, data: nil)
    super()

    @exported_path = nil
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
    @exported_path = destination_path

    File.open(destination_path, "w") do |fd|
      fd.write(@data)
    end
  end

  def reimport_after_export
    @data = File.read(@exported_path)
    commit(force: true)
  end

  def commit(force: false)
    commit_content(file: @data_path, content: encrypt(plain: @data), force: force)
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

  def commit(force: false)
    commit_content(file: @index_path, content: encrypt(plain: @description), force: force)
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

  def search(search_term: nil, action: :none)
    indexes = Array.new
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      print index
      case action
      when :cat
        if !index.is_binary?
          puts index.get_data
        else
          puts "Not catting binary data!"
        end
      when :export
        destination_file = File.basename(index.description)
        index.get_data.export(destination_file: destination_file)
      when :open
        destination_file = File.basename(index.description)
        index.get_data.export(destination_file: destination_file)
        shred_file(file: open_exported(file: destination_file), delay: 10)
      when :edit
        destination_file = File.basename(index.description)
        data = index.get_data
        data.export(destination_file: destination_file)
        exported_file = edit_exported(file: destination_file)
        data.reimport_after_export
        shred_file(file: exported_file)
      end
    end
  end

  def import_recursive(directory:, dest_dir: nil)
    Dir.glob("#{directory}/**/*").each do |source_file|
      next if File.directory?(source_file)
      file = source_file.sub("#{directory}/", "")
      add(description: file, file: source_file, dest_dir: dest_dir)
    end
  end

  def add(description: nil, file: nil, dest_dir: nil, force: false)
    src_path = file.gsub("//", "/")

    dest_path = if dest_dir.nil?
      src_path
    else
      if dest_dir.include?(".")
        dest_dir
      else
        "#{dest_dir}/#{File.basename(file)}".gsub("//", "/")
      end
    end

    hash = hash_path(dest_path)

    if file.nil?
      print "Data: "
      data = $stdin.gets.chomp
    elsif !File.exists?(src_path)
      puts "ERROR: #{file} does not exist!"
      exit(3)
    else
      puts "Importing #{src_path} -> #{dest_path}"
      data = File.read(src_path)
    end
    description = dest_path if description.nil?

    index = Index.new(index_file: "#{hash}.index", description: description)
    data = index.get_data(data: data)

    data.commit(force: force)
    index.commit(force: force)
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

  def shred_all_exported
    puts "Shredding all exported files"
    Dir.glob("#{$export_dir}/*").each do |file|
      shred_file(file: file)
    end
  end

  private def shred_file(file:, delay: 0)
    %x{which shred}
    sleep(delay)
    if $?.success?
      run_command("shred -vu #{file}")
    else
      run_command("rm -Pfv #{file}")
    end
  end

  private def open_exported(file:)
    file_path = "#{$export_dir}/#{file}"
    case ENV['UNAME']
    when 'Darwin'
      run_command("open #{file_path}")
    when 'Microsoft'
      run_command("winopen #{file_path}")
    else
      run_command("termux-open #{file_path}")
    end
    file_path
  end

  private def edit_exported(file:)
    file_path = "#{$export_dir}/#{file}"
    edit_cmd= "#{$edit_cmd} #{file_path}"
    puts edit_cmd
    system(edit_cmd)
    file_path
  end

  private def run_command(cmd)
    puts "#{cmd}: #{%x{#{cmd}}}"
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
    path_string.gsub("//", "/").split("/").each do |part|
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
      search SEARCHTERM
      cat SEARCHTERM
      add DESCRIPTION
      export|open FILE
      import FILE [DEST_DIRECTORY] [force]
      import_r DIRECTORY [DEST_DIRECTORY]
      rm SEARCHTERM
      sync|status|commit|reset
      shred
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
      when 'search'
        geheim.search(search_term: argv[1])
      when 'cat'
        geheim.search(search_term: argv[1], action: :cat)
      when 'export'
        geheim.search(search_term: argv[1], action: :export)
      when 'edit'
        geheim.search(search_term: argv[1], action: :edit)
      when 'open'
        geheim.search(search_term: argv[1], action: :open)
      when 'add'
        geheim.add(description: argv[1])
      when 'import'
        geheim.add(file: argv[1], dest_dir: argv[2], force: !argv[3].nil?)
      when 'import_r'
        geheim.import_recursive(directory: argv[1], dest_dir: argv[2])
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
      when 'shred'
        geheim.shred_all_exported
      else
        geheim.search(search_term: action)
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
