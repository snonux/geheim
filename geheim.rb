#!/usr/bin/env ruby

require 'base64'
require 'digest'
require 'digest/sha2'
require 'fileutils'
require 'io/console'
require 'openssl'
require 'json'

# Configuration
class Config
  config_file = "#{ENV['HOME']}/.config/geheim.json"

  default_config = {
    data_dir: "#{ENV['HOME']}/git/geheimlager".freeze,
    export_dir: "#{ENV['HOME']}/.geheimlagerexport".freeze,
    key_file: "#{ENV['HOME']}/.geheimlager.key".freeze,
    key_length: 32,
    enc_alg: 'AES-256-CBC'.freeze,
    add_to_iv: 'Hello world'.freeze,
    edit_cmd: "nvim --cmd 'set noswapfile' --cmd 'set nobackup' --cmd 'set nowritebackup'".freeze,
    gnome_clipboard_cmd: 'gpaste-client'.freeze,
    macos_clipboard_cmd: 'pbcopy'.freeze,
    sync_repos: %w[git1 git2].freeze
  }

  @@config = begin
    default_config.merge(JSON.parse(File.read(config_file))).freeze
  rescue StandardError => e
    puts "Unable to read #{config_file}, using defaults! #{e}"
    default_config.freeze
  end

  def self.method_missing(method_name)
    raise "Unknown config key '#{method_name}'" unless respond_to_missing?(method_name)

    @@config[method_name]
  end

  def self.respond_to_missing?(method_name)
    @@config.key?(method_name)
  end
end

# Logging capabilities
module Log
  def log(message)
    out message, '>'
  end

  def warn(message)
    out message, 'WARN'
  end

  def prompt(message)
    out message, '<', :nonl
  end

  def fatal(message)
    out message, 'FATAL'
    exit 3
  end

  private

  def out(message, prefix, flag = :none)
    message = message.to_s unless message.instance_of?(String)
    message.split("\n").each do |line|
      if flag == :nonl
        print "#{prefix} #{line}"
      else
        puts "#{prefix} #{line}"
      end
    end
  end
end

# Git versioning
module Git
  include Log

  def initialize
    super()
    @wd = Dir.pwd
  end

  def git_add(file:)
    dirname = File.dirname(file)
    basename = File.basename(file)
    Dir.chdir(dirname)
    log `git add "#{basename}"`
    Dir.chdir(@wd)
  end

  def git_rm(file:)
    dirname = File.dirname(file)
    basename = File.basename(file)
    Dir.chdir(dirname)
    log `git rm "#{basename}"`
    Dir.chdir(@wd)
  end

  def git_status
    Dir.chdir(Config.data_dir)
    log `git status`
    Dir.chdir(@wd)
  end

  def git_commit
    Dir.chdir(Config.data_dir)
    log `git commit -a -m 'Changing stuff, not telling what in commit history'`
    Dir.chdir(@wd)
  end

  def git_reset
    Dir.chdir(Config.data_dir)
    log `git reset --hard`
    Dir.chdir(@wd)
  end

  def git_sync
    log "Synchronising #{Config.data_dir}"
    Dir.chdir(Config.data_dir)
    Config.sync_repos.each do |repo|
      log `git pull #{repo} master`
      log `git push #{repo} master`
    end
    log `git status`
    Dir.chdir(@wd)
  end
end

# Encryption functionality
module Encryption
  include Log
  @@key = nil

  def initialize
    super()
    return unless @@key.nil?

    pin = read_pin
    # Set up initialization vector
    iv = "#{pin * 2}#{Config.add_to_iv}#{pin * 2}"
    @@iv = iv[0..15]
    # ... and the encryption key!
    @@key = enforce_key_length(File.read(Config.key_file), Config.key_length)
  end

  def encrypt(plain:)
    aes = OpenSSL::Cipher::Cipher.new(Config.enc_alg)
    aes.encrypt
    aes.key = @@key
    aes.iv = @@iv

    encrypted = aes.update(plain)
    encrypted << aes.final

    encrypted
  end

  def decrypt(encrypted:)
    aes = OpenSSL::Cipher::Cipher.new(Config.enc_alg)
    aes.decrypt
    aes.key = @@key
    aes.iv = @@iv

    plain = aes.update(encrypted)
    plain << aes.final
    plain
  end

  def test
    plain_input = 'foo bar baz'
    encrypted = encrypt(plain: plain_input)
    plain = decrypt(encrypted: encrypted)
    pp plain == plain_input
  end

  private

  def enforce_key_length(key, force_size)
    new_key = key
    new_key += key while new_key.size < force_size
    new_key[0..force_size - 1]
  end

  def read_pin
    return ENV['PIN'] if ENV['PIN']

    prompt 'PIN: '
    return $stdin.gets.chomp if `uname`.include?('Android')

    $stdin.noecho(&:gets).chomp
  end
end

# Comitting a file
class CommitFile
  include Git
  include Log

  def commit_content(file:, content:, force: false)
    fatal "#{file} already exists" if File.exist?(file) && !force

    dirname = File.dirname(file)
    unless File.directory?(dirname)
      log "Creating #{dirname}"
      FileUtils.mkdir_p(dirname)
    end

    log "Writing #{file}"
    File.open(file, 'w') { |fd| fd.write(content) }
    git_add(file: file)
  end
end

# Clipboard support
module Clipboard
  include Log
  @clipboard_cmd = nil

  def initialize
    super()
    @clipboard_cmd =
      ENV['UNAME'] == 'Darwin' ? Config.macos_clipboard_cmd : Config.gnome_clipboard_cmd
  end

  def paste(data)
    fatal "Can't paste to clipboard" if @clipboard_cmd.nil?
    user, password, other = extract(data.to_s)
    read, write = IO.pipe
    spawn(@clipboard_cmd, in: read)
    write.write(password)
    puts other
    log "Pasted password for user '#{user}' to the clipboard"
  end

  private

  def extract(data)
    parts = data.match(/(?<User>\S+):(?<Password>\S+)/)
    cleared_data = data.gsub(/(\S+):\S+/, '\1:CENSORED')
    [parts['User'], parts['Password'], cleared_data]
  end
end

# Secret data store
class GeheimData < CommitFile
  include Encryption
  include Git
  include Log

  attr_accessor :data, :exported_path

  def initialize(data_file:, data: nil)
    super()

    @exported_path = nil
    @data_path = "#{Config.data_dir}/#{data_file}"
    @data = data.nil? ? decrypt(encrypted: File.read(@data_path)) : data
  rescue StandardError => e
    fatal e
  end

  def to_s
    "\t#{@data.gsub("\n", "\n\t")}\n"
  end

  def rm
    log "Deleting #{@data_path}"
    git_rm(file: @data_path)
  end

  def export(destination_file:)
    destination_dir = "#{Config.export_dir}/#{File.dirname(destination_file)}"
    unless File.directory?(destination_dir)
      log "Creating #{destination_dir}"
      FileUtils.mkdir_p(destination_dir)
    end

    destination_path = "#{destination_dir}/#{File.basename(destination_file)}"
    log "Exporting to #{destination_path}"
    File.open(destination_path, 'w') { |fd| fd.write(@data) }
    @exported_path = destination_path
  end

  def reimport_after_export
    @data = File.read(@exported_path)
    commit(force: true)
  end

  def commit(force: false)
    commit_content(file: @data_path, content: encrypt(plain: @data), force: force)
  end
end

# Data store's encrypted index
class Index < CommitFile
  attr_accessor :description, :data_file, :index_path

  include Encryption
  include Log

  def initialize(index_file:, description: nil)
    super()
    @data_file = index_file.sub('.index', '.data')
    @index_path = "#{Config.data_dir}/#{index_file}"
    @hash = File.basename(index_file).sub('.index', '')
    @description = description.nil? ? decrypt(encrypted: File.read(@index_path)) : description
  end

  def binary?
    if @description.include?('.txt')
      false
    elsif @description.include?('.README')
      false
    elsif @description.include?('.conf')
      false
    elsif @description.include?('.csv')
      false
    elsif @description.include?('.md')
      false
    else
      @description.include?('.')
    end
  end

  def get_data(data: nil)
    GeheimData.new(data_file: @data_file, data: data)
  end

  def to_s
    binary = binary? ? '(BINARY) ' : ''
    "#{@description}; #{binary}...#{@hash[-11...-1]}\n"
  end

  def <=>(other)
    @description <=> other.description
  end

  def rm
    log "Deleting #{@index_path}"
    git_rm(file: @index_path)
  end

  def commit(force: false)
    commit_content(file: @index_path, content: encrypt(plain: @description), force: force)
  end
end

# Secret store main class
class Geheim
  include Clipboard
  include Log

  def initialize
    super()
    unless File.directory?(Config.data_dir)
      log "Creating #{Config.data_dir}"
      FileUtils.mkdir_p(Config.data_dir)
    end
    @regex_cache = {}
  end

  def fzf(flag = :none)
    # Need to read an index first before opening the pipe to initialize
    # the encryption PIN.
    fzf = nil
    walk_indexes do |index|
      fzf = IO.popen('fzf', 'r+') if fzf.nil?
      fzf.write(index)
    end
    fzf.close_write
    match = fzf.read.chomp
    log match unless flag == :silent
    match.split(';').first
  end

  def search(search_term: nil, action: :none)
    ec = 1
    search_term = fzf(:silent) if search_term.nil?
    indexes = []
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      print index
      ec = 0
      case action
      when :cat, :paste
        if index.binary?
          log 'Not displaying/pasting binary data!'
          ec = 2
        elsif action == :paste
          paste(index.get_data)
        else
          puts index.get_data
        end
      when :pathexport
        index.get_data.export(destination_file: index.description)
      when :export
        destination_file = File.basename(index.description)
        index.get_data.export(destination_file: destination_file)
      when :open
        destination_file = File.basename(index.description)
        index.get_data.export(destination_file: destination_file)
        shred_file(file: open_exported(file: destination_file), delay: 0)
      when :edit
        destination_file = File.basename(index.description)
        data = index.get_data
        data.export(destination_file: destination_file)
        external_edit(file: destination_file)
        data.reimport_after_export
      end
      index.description
    end
    ec
  end

  def add(description:)
    hash = hash_path(description)

    log 'Data: '
    data = $stdin.gets.chomp
    index = Index.new(index_file: "#{hash}.index", description: description)
    data = index.get_data(data: data)

    data.commit
    index.commit
  end

  def import(description: nil, action: nil, file: nil, dest_dir: nil, force: false)
    src_path = file.gsub('//', '/').gsub(%r{^\./}, '')
    dest_path = if dest_dir.nil?
                  src_path
                elsif dest_dir.include?('.')
                  dest_dir
                else
                  "#{dest_dir}/#{File.basename(file)}".gsub('//', '/')
                end

    hash = hash_path(dest_path)

    fatal "#{file} does not exist!" unless File.exist?(src_path)
    log "Importing #{src_path} -> #{dest_path}"
    data = File.read(src_path)
    shred_file(file: src_path) if action == :newtxt
    description = dest_path if description.nil?

    index = Index.new(index_file: "#{hash}.index", description: description)
    data = index.get_data(data: data)

    data.commit(force: force)
    index.commit(force: force)
  end

  def import_recursive(directory:, dest_dir: nil)
    Dir.glob("#{directory}/**/*").each do |source_file|
      next if File.directory?(source_file)

      file = source_file.sub("#{directory}/", '')
      import(description: file, action: :import, file: source_file, dest_dir: dest_dir)
    end
  end

  def rm(search_term:)
    indexes = []
    walk_indexes(search_term: search_term) do |index|
      indexes << index
    end
    indexes.sort.each do |index|
      loop do
        log index
        prompt 'You really want to delete this? (y/n): '
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
    log 'Shredding all exported files'
    ec = 0
    Dir.glob("#{Config.export_dir}/*").each do |file|
      next unless File.file?(file)

      if (ec_ = shred_file(file: file)).positive?
        ec = ec_
      end
    end
    ec
  end

  private

  def shred_file(file:, delay: 0)
    sleep(delay) if delay.positive?
    `which shred`
    if $?.success?
      run_command("shred -vu #{file}")
    else
      run_command("rm -Pfv #{file}")
    end
  end

  def open_exported(file:)
    file_path = "#{Config.export_dir}/#{file}"

    case ENV['UNAME']
    when 'Darwin'
      run_command("open #{file_path}")
    when 'Microsoft'
      run_command("winopen #{file_path}")
    when 'Linux'
      run_command("evince #{file_path}")
    else
      # Termux (Android)
      run_command("termux-open #{file_path}")
    end
    file_path
  end

  def external_edit(file:)
    file_path = "#{Config.export_dir}/#{file}"
    edit_cmd = "#{Config.edit_cmd} #{file_path}"
    log edit_cmd
    system(edit_cmd)
    file_path
  end

  def run_command(cmd)
    log "#{cmd}: #{`#{cmd}`}"
    $?.exitstatus
  end

  def walk_indexes(search_term: nil)
    @regex_cache[search_term] = Regexp.new(/#{search_term}/) unless @regex_cache.key?(search_term)
    regex = @regex_cache[search_term]
    Dir.glob("#{Config.data_dir}/**/*.index").each do |index_file|
      index = Index.new(index_file: index_file.sub(Config.data_dir, ''))
      yield index if search_term.nil? || index.description.force_encoding('UTF-8').match(regex)
    end
  end

  def hash_path(path_string)
    path = []
    path_string.gsub('//', '/').split('/').each do |part|
      path << Digest::SHA256.hexdigest(part)
    end
    path.join('/')
  end
end

# Command line interface
class CLI
  include Git
  include Log

  def initialize(interactive: false)
    super()
    @interactive = interactive
  end

  def help
    log <<-HELP
      ls
      SEARCHTERM
      search SEARCHTERM
      cat SEARCHTERM
      get SEARCHTERM
      add DESCRIPTION
      export|pathexport|open|edit FILE
      import FILE [DEST_DIRECTORY] [force]
      import_r DIRECTORY [DEST_DIRECTORY]
      rm SEARCHTERM
      sync|status|commit|reset|fullcommit
      shred
      help
      shell
    HELP
  end

  def shell_loop(argv)
    last_result = nil
    ec = 0

    loop do
      if argv.length == 0 or @interactive
        @interactive ||= true
        print '% '
        argv = $stdin.gets.chomp.split(' ')
      end

      geheim = Geheim.new
      action = argv.first
      search_term = argv.length < 2 ? last_result : argv[1]

      ec = case action
           when 'ls'
             geheim.search(search_term: '.')
           when 'search'
             geheim.search(search_term: search_term)
           when 'cat'
             geheim.search(search_term: search_term, action: :cat)
           when 'paste'
             geheim.search(search_term: search_term, action: :paste)
           when 'export'
             geheim.search(search_term: search_term, action: :export)
           when 'pathexport'
             geheim.search(search_term: search_term, action: :pathexport)
           when 'edit'
             geheim.search(search_term: search_term, action: :edit)
           when 'open'
             geheim.search(search_term: search_term, action: :open)
           when 'add'
             geheim.add(description: search_term)
           when 'import'
             geheim.import(file: search_term, dest_dir: argv[2], force: !argv[3].nil?)
           when 'import_r'
             geheim.import_recursive(directory: search_term, dest_dir: argv[2])
           when 'rm'
             geheim.rm(search_term: search_term)
           when 'help'
             help
           when 'shell'
             @interactive = true
             log 'Switching to interactive mode'
           when 'exit'
             @interactive = false
             log 'Good bye'
           when 'status'
             git_status
           when 'commit'
             git_commit
           when 'reset'
             git_reset
           when 'sync'
             git_sync
           when 'fullcommit'
             git_sync
             git_commit
             git_sync
           when 'shred'
             geheim.shred_all_exported
           when 'last'
             puts last_result
             last_result
           when nil
             last_result = geheim.fzf
           else
             last_result = geheim.search(search_term: action)
           end
      break unless @interactive
    end

    ec
  end
end

exit(CLI.new.shell_loop(ARGV))
