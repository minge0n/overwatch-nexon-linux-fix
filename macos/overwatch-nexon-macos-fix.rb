#!/usr/bin/ruby
require 'base64'
require 'digest'
require 'fileutils'
require 'find'
require 'json'
require 'open3'
require 'tempfile'

class MacOSFix
  DROP = 'DDFB16CD4931C973A2037D3FC83A4D7D775D05E4'
  CROSS = 'A99D5B79E9F1CDA59CDAB6373169D5353F5874C6'
  PIN = '0563B8630D62D75ABBC8AB1E4BDFB5A899B24D43'
  PIN_SHA256 = '3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c'
  DROP_SHA256 = '552f7bdcf1a7af9e6ce672017f4f12abf77240c78e761ac203d1d9d20ac89988'
  SOURCE = File.expand_path(__dir__)

  def initialize
    raise 'macOS is required.' unless RUBY_PLATFORM.include?('darwin')
    File.umask(0077)
    @prefix = resolve_prefix
    @registry = File.join(@prefix, 'system.reg')
    raise 'system.reg must be a regular file, not a symlink.' unless File.file?(@registry) && !File.symlink?(@registry)
    @state = File.join(@prefix, '.overwatch-nexon-macos-fix')
    raise 'State directory must not be a symlink.' if File.symlink?(@state)
    @targets = {}
    ['Software', 'Software\\\\Wow6432Node'].each do |view|
      base = view + '\\\\Microsoft\\\\SystemCertificates\\\\'
      @targets[base + 'Root\\\\Certificates\\\\' + DROP] = nil
      @targets[base + 'CA\\\\Certificates\\\\' + CROSS] = certificate('cross-g4.der', CROSS)
      @targets[base + 'Root\\\\Certificates\\\\' + PIN] = certificate('assured-id-root.der', PIN)
    end
  end

  def resolve_prefix
    if ENV['OW_PREFIX'] && !ENV['OW_PREFIX'].empty?
      return File.realpath(File.expand_path(ENV['OW_PREFIX']))
    end
    roots = [
      '~/Library/Application Support/CrossOver/Bottles',
      '~/Library/Containers/com.isaacmarovitz.Whisky/Bottles',
      '~/Library/Containers/com.isaacmarovitz.Whisky/Data/Bottles',
      '~/Library/Application Support/com.isaacmarovitz.Whisky/Bottles',
      '~/.wine'
    ].map { |path| File.expand_path(path) }
    roots << File.expand_path(ENV['WINEPREFIX']) if ENV['WINEPREFIX']
    prefixes = []
    roots.uniq.each do |root|
      next unless File.directory?(root)
      Find.find(root) do |path|
        Find.prune if File.basename(path) == 'dosdevices' && File.directory?(path)
        next unless File.basename(path).casecmp('gamescale64.dll').zero? && File.file?(path)
        parent = File.dirname(path)
        until parent == '/'
          if File.file?(File.join(parent, 'system.reg'))
            prefixes << File.realpath(parent)
            break
          end
          parent = File.dirname(parent)
        end
      end
    end
    prefixes.uniq!
    raise 'No Overwatch prefix found. Set OW_PREFIX to the directory containing system.reg.' if prefixes.empty?
    raise "Multiple prefixes found. Set OW_PREFIX explicitly:\n#{prefixes.join("\n")}" if prefixes.length > 1
    prefixes.first
  end

  def certificate(file, fingerprint)
    der = File.binread(File.join(SOURCE, 'certs', file))
    raise "Certificate fingerprint mismatch: #{file}" unless Digest::SHA1.hexdigest(der).upcase == fingerprint
    der
  end

  def sections(text)
    text.scan(/^\[[^\n]*\].*?(?=^\[|\z)/m)
  end

  def key(section)
    section[/\A\[([^\]]+)\]/, 1]
  end

  def target?(name)
    @targets.keys.any? { |target| target.casecmp(name).zero? }
  end

  def digest(section)
    return nil unless section
    chunks = []
    collecting = false
    section.each_line do |line|
      if line.start_with?('"Blob"=hex:')
        line = line.delete_prefix('"Blob"=hex:')
        collecting = true
      end
      next unless collecting
      more = line.rstrip.end_with?('\\')
      chunks << line.strip.delete_suffix('\\').delete(',').delete(' ')
      break unless more
    end
    hex = chunks.join
    return nil unless hex.match?(/\A(?:[0-9a-fA-F]{2})+\z/)
    blob = [hex].pack('H*')
    offset = 0
    while offset + 12 <= blob.bytesize
      property, _encoding, length = blob.byteslice(offset, 12).unpack('V3')
      return nil if offset + 12 + length > blob.bytesize
      return Digest::SHA1.hexdigest(blob.byteslice(offset + 12, length)).upcase if property == 32
      offset += 12 + length
    end
    nil
  end

  def entry(name, der)
    hash = Digest::SHA1.digest(der)
    blob = [3, 1, hash.bytesize].pack('V3') + hash + [32, 1, der.bytesize].pack('V3') + der
    pieces = blob.bytes.map { |byte| '%02x' % byte }
    lines = pieces.each_slice(24).map { |bytes| bytes.join(',') }
    "[#{name}]\n\"Blob\"=hex:" + lines.join(",\\\n  ") + "\n\n"
  end

  def replace_targets(text, replacements)
    preamble = text[/\A.*?(?=^\[|\z)/m]
    kept = sections(text).reject { |section| target?(key(section)) }.join
    result = preamble + kept
    result += "\n" unless result.end_with?("\n")
    result + replacements.join
  end

  def atomic_write(path, contents)
    mode = File.exist?(path) ? File.stat(path).mode & 0777 : 0600
    temporary = Tempfile.new('.overwatch-nexon-', File.dirname(path))
    begin
      temporary.binmode
      temporary.write(contents)
      temporary.flush
      temporary.fsync
      temporary.chmod(mode)
      temporary.close
      File.rename(temporary.path, path)
    ensure
      temporary.close!
    end
  end

  def idle!
    output, status = Open3.capture2('/usr/bin/pgrep', '-x', 'wine|wine64|wine32on64|wineserver|wineserver64|wine64-preloader|wine-preloader|Battle.net.exe|Agent.exe')
    raise 'Cannot check running Wine processes.' unless [0, 1].include?(status.exitstatus)
    raise "Close all Wine, Battle.net and game processes first (PIDs: #{output.split.join(', ')})." if status.success?
  end

  def read_backup
    backup = JSON.parse(File.binread(File.join(@state, 'backup.json')))
    unless backup['version'] == 1 && backup['prefix'] == @prefix &&
           backup['sections'].is_a?(Hash) && backup['sections'].keys.sort == @targets.keys.sort
      raise 'Invalid backup; refusing to modify the prefix.'
    end
    backup['sections'].map do |name, encoded|
      value = Base64.strict_decode64(encoded)
      unless value.empty? || (sections(value).join == value && sections(value).all? { |part| key(part).casecmp(name).zero? })
        raise 'Invalid certificate section in backup.'
      end
      value
    end
  end

  def prepare
    text = File.binread(@registry)
    current = sections(text)
    replacements = []
    @targets.each do |name, der|
      next unless der
      matching = current.select { |part| key(part).casecmp(name).zero? }
      fingerprint = Digest::SHA1.hexdigest(der).upcase
      replacements << if matching.length == 1 && digest(matching.first) == fingerprint
                        matching.first
                      else
                        entry(name, der)
                      end
    end
    ready = @targets.all? do |name, der|
      matching = current.select { |part| key(part).casecmp(name).zero? }
      der ? matching.length == 1 && digest(matching.first) == Digest::SHA1.hexdigest(der).upcase : matching.empty?
    end
    atomic_write(@registry, replace_targets(text, replacements)) unless ready
  end

  def install
    idle!
    FileUtils.mkdir_p(@state, :mode => 0700)
    lock do
      unless File.file?(File.join(@state, 'backup.json'))
        extras = Dir.children(@state).reject { |name| name == 'lock' || name.start_with?('.overwatch-nexon-') }
        raise 'Backup is missing from an existing installation; refusing to overwrite it.' unless extras.empty?
        current = sections(File.binread(@registry))
        originals = @targets.keys.each_with_object({}) do |name, saved|
          saved[name] = Base64.strict_encode64(current.select { |part| key(part).casecmp(name).zero? }.join)
        end
        atomic_write(File.join(@state, 'backup.json'), JSON.generate('version' => 1, 'prefix' => @prefix, 'sections' => originals))
      end
      read_backup
      out, err, status = Open3.capture3('bash', File.join(SOURCE, 'build.sh'), @state)
      raise "Native build failed. Registry unchanged.\n#{out}#{err}" unless status.success?
      prepare
    end
    puts "Installed certificate configuration: #{@prefix}"
    puts 'Experimental macOS port. Always launch Wine through run. Gameplay is NOT VERIFIED.'
  end

  def lock
    File.open(File.join(@state, 'lock'), File::RDWR | File::CREAT, 0600) do |file|
      raise 'Another fix command is using this prefix.' unless file.flock(File::LOCK_EX | File::LOCK_NB)
      yield
    end
  end

  def status
    read_backup
    current = sections(File.binread(@registry))
    valid = @targets.all? do |name, der|
      matching = current.select { |part| key(part).casecmp(name).zero? }
      der ? matching.length == 1 && digest(matching.first) == Digest::SHA1.hexdigest(der).upcase : matching.empty?
    end
    raise 'Prefix certificate configuration is incomplete. Close Wine and rerun install.' unless valid
    %w[libow-nexon-trust.dylib trust-probe].each do |name|
      raise "Native file missing: #{name}. Rerun install." unless File.file?(File.join(@state, name))
    end
    puts "Prefix certificates: OK (#{@prefix})"
  end

  def doctor
    status
    probe = File.join(@state, 'trust-probe')
    plain, plain_err, plain_status = Open3.capture3([probe, probe])
    filtered, filtered_err, filtered_status = Open3.capture3({'DYLD_INSERT_LIBRARIES' => File.join(@state, 'libow-nexon-trust.dylib')}, [probe, probe])
    raise "Native probe failed:\n#{plain_err}#{filtered_err}" unless plain_status.success? && filtered_status.success?
    expected = plain.lines.reject { |line| line.split.last == DROP_SHA256 }
    expected << "cert 2 #{PIN_SHA256}\n" unless expected.any? { |line| line.split.last == PIN_SHA256 }
    raise 'Native certificate filtering failed or changed unrelated certificates.' unless filtered.lines.sort == expected.sort
    removed = plain.lines.count { |line| line.split.last == DROP_SHA256 }
    puts "Native macOS API filtering: OK (#{removed} G4 entries excluded; pinned root present)"
    log = File.join(@state, 'last-run.log')
    if File.file?(log) && File.binread(log).lines.any? { |line| line.start_with?('filtered ') }
      puts 'Last wrapped process called the filtered macOS API. This does not prove Wine chain construction or gameplay.'
    end
    puts 'Wine certificate chain and game launch: NOT VERIFIED. Inspect +crypt,+chain,+wintrust logs from an actual game launch.'
    2
  end

  def run(arguments)
    raise 'Usage: run /absolute/path/to/native/wine64 Battle.net.exe [arguments]' if arguments.empty?
    binary = if arguments.first.include?('/')
               File.realpath(arguments.shift)
             else
               name = arguments.shift
               ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) }
             end
    raise 'Wine executable not found.' unless binary && File.file?(binary) && File.executable?(binary)
    magic = File.binread(binary, 4).unpack1('H*')
    raise 'Use a native Mach-O Wine loader, not a shell script, open or env.' unless %w[cffaedfe cefaedfe cafebabe bebafeca cafebabf bfbafeca feedfacf].include?(magic)
    raise 'Do not launch through SIP-protected system executables.' if binary.start_with?('/usr/bin/', '/bin/', '/System/')
    idle!
    read_backup
    lock do
      prepare
      status
      library = File.join(@state, 'libow-nexon-trust.dylib')
      raise 'The prefix path cannot contain a colon (DYLD path separator).' if library.include?(':')
      log = File.join(@state, 'last-run.log')
      atomic_write(log, '')
      environment = {
        'WINEPREFIX' => @prefix,
        'DYLD_INSERT_LIBRARIES' => [library, ENV['DYLD_INSERT_LIBRARIES']].compact.reject(&:empty?).join(':'),
        'OW_NEXON_FILTER_LOG' => log
      }
      puts 'Launching with per-process certificate filtering. Injection may be blocked by the runtime signing policy.'
      STDOUT.flush
      exec(environment, [binary, binary], *arguments)
    end
  end

  def uninstall
    idle!
    read_backup
    lock do
      replacements = read_backup
      atomic_write(@registry, replace_targets(File.binread(@registry), replacements))
      FileUtils.remove_entry(@state)
    end
    puts 'Restored only the backed-up certificate entries. Other prefix settings and macOS Keychains were not changed.'
  end
end

begin
  command = ARGV.shift
  unless %w[install status doctor run uninstall].include?(command)
    warn 'Usage: OW_PREFIX=/path/to/prefix ruby macos/overwatch-nexon-macos-fix.rb install|status|doctor|run <wine-loader> <exe>|uninstall'
    exit 2
  end
  fix = MacOSFix.new
  case command
  when 'run' then fix.run(ARGV)
  when 'doctor' then exit fix.doctor
  when 'install' then fix.install
  when 'status' then fix.status
  when 'uninstall' then fix.uninstall
  end
rescue StandardError => error
  warn "Error: #{error.message}"
  exit 1
end
