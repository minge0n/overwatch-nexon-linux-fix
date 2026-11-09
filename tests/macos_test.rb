require 'minitest/autorun'
require 'tmpdir'
require 'fileutils'
require 'open3'
require 'digest'
require 'json'

class MacOSFixTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  CLI = File.join(ROOT, 'macos/overwatch-nexon-macos-fix.rb')
  DROP = 'DDFB16CD4931C973A2037D3FC83A4D7D775D05E4'
  CROSS = 'A99D5B79E9F1CDA59CDAB6373169D5353F5874C6'
  PIN = '0563B8630D62D75ABBC8AB1E4BDFB5A899B24D43'
  PIN_SHA256 = '3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c'
  DROP_SHA256 = '552f7bdcf1a7af9e6ce672017f4f12abf77240c78e761ac203d1d9d20ac89988'

  def setup
    @dir = Dir.mktmpdir('ow macos test ')
    @prefix = File.join(@dir, 'Overwatch Bottle')
    FileUtils.mkdir_p(@prefix)
    @unrelated = "[Software\\\\Example] 1\n\"keep\"=\"before\"\n\n"
    @g4 = "[Software\\\\Microsoft\\\\SystemCertificates\\\\Root\\\\Certificates\\\\#{DROP}] 1\n\"Blob\"=hex:01,02,03\n\n"
    @original = "WINE REGISTRY Version 2\n\n" + @unrelated + @g4
    File.write(File.join(@prefix, 'system.reg'), @original)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def cli(*args, env: {})
    Open3.capture3({'OW_PREFIX' => @prefix}.merge(env), '/usr/bin/ruby', CLI, *args)
  end

  def install
    out, err, result = cli('install')
    assert result.success?, "install failed: #{out}\n#{err}"
  end

  def test_install_replaces_only_target_certificates_and_is_idempotent
    install
    registry = File.read(File.join(@prefix, 'system.reg'))
    assert_includes registry, @unrelated
    refute_includes registry, "Root\\\\Certificates\\\\#{DROP}]"
    assert_includes registry, "CA\\\\Certificates\\\\#{CROSS}]"
    assert_includes registry, "Root\\\\Certificates\\\\#{PIN}]"
    first = registry
    install
    assert_equal first, File.read(File.join(@prefix, 'system.reg'))
    out, err, result = cli('status')
    assert result.success?, "#{out}\n#{err}"
  end

  def test_uninstall_preserves_later_unrelated_registry_changes
    install
    path = File.join(@prefix, 'system.reg')
    File.write(path, File.read(path).sub('"before"', '"after"'))
    out, err, result = cli('uninstall')
    assert result.success?, "#{out}\n#{err}"
    assert_equal @original.sub('"before"', '"after"'), File.read(path)
    refute File.exist?(File.join(@prefix, '.overwatch-nexon-macos-fix'))
  end

  def test_corrupt_backup_blocks_changes_instead_of_losing_original_state
    install
    path = File.join(@prefix, 'system.reg')
    before = File.binread(path)
    File.write(File.join(@prefix, '.overwatch-nexon-macos-fix/backup.json'), '{}')
    _out, _err, result = cli('uninstall')
    refute result.success?
    assert_equal before, File.binread(path)
  end

  def test_invalid_prefix_and_missing_command_do_not_create_state
    FileUtils.rm(File.join(@prefix, 'system.reg'))
    _out, _err, result = cli('install')
    refute result.success?
    refute File.exist?(File.join(@prefix, '.overwatch-nexon-macos-fix'))
    File.write(File.join(@prefix, 'system.reg'), @original)
    _out, _err, result = cli('run')
    refute result.success?
    assert_equal @original, File.read(File.join(@prefix, 'system.reg'))
  end

  def test_doctor_requires_real_wine_evidence_not_only_native_probe
    install
    out, err, result = cli('doctor')
    refute result.success?
    assert_includes out + err, 'Wine'
    assert_includes out + err, 'NOT VERIFIED'
  end

  def test_run_repairs_reimported_g4_and_injects_the_actual_child
    install
    path = File.join(@prefix, 'system.reg')
    File.open(path, 'a') { |file| file.write(@g4) }
    probe = File.join(@prefix, '.overwatch-nexon-macos-fix/trust-probe')
    out, err, result = cli('run', probe)
    assert result.success?, "#{out}\n#{err}"
    refute_includes out, DROP_SHA256
    refute_includes File.read(path), "Root\\Certificates\\#{DROP}]"
    assert_includes File.read(File.join(@prefix, '.overwatch-nexon-macos-fix/last-run.log')), 'filtered '
  end

  def test_install_recovers_an_empty_interrupted_state_directory
    FileUtils.mkdir_p(File.join(@prefix, '.overwatch-nexon-macos-fix'))
    install
    out, err, result = cli('uninstall')
    assert result.success?, "#{out}\n#{err}"
    assert_equal @original, File.read(File.join(@prefix, 'system.reg'))
  end

  def test_registry_contains_wine_serialized_public_der_certificates
    install
    registry = File.read(File.join(@prefix, 'system.reg'))
    [[CROSS, 'cross-g4.der'], [PIN, 'assured-id-root.der']].each do |thumb, file|
      section = registry.split(/(?=^\[)/).find { |part| part.lines.first.include?(thumb) }
      bytes = section.split('"Blob"=hex:', 2).last.delete(" ,\\n\r").scan(/../).map { |hex| Integer(hex, 16) }.pack('C*')
      assert_equal [3, 1, 20], bytes.unpack('V3')
      assert_equal thumb.downcase, bytes.byteslice(12, 20).unpack1('H*')
      property, encoding, length = bytes.byteslice(32, 12).unpack('V3')
      assert_equal [32, 1], [property, encoding]
      assert_equal File.binread(File.join(ROOT, 'macos/certs', file)), bytes.byteslice(44, length)
    end
  end

  def test_native_filter_preserves_other_certificates_and_error_statuses
    output = File.join(@dir, 'native output')
    out, err, result = Open3.capture3('bash', File.join(ROOT, 'macos/build.sh'), output)
    assert result.success?, "native build failed: #{out}\n#{err}"
    probe = File.join(output, 'trust-probe')
    baseline, base_err, base_result = Open3.capture3([probe, probe])
    assert base_result.success?, base_err
    filtered, filtered_err, filtered_result = Open3.capture3(
      {'DYLD_INSERT_LIBRARIES' => File.join(output, 'libow-nexon-trust.dylib')}, [probe, probe])
    assert filtered_result.success?, filtered_err
    expected = baseline.lines.reject { |line| line.split.last == DROP_SHA256 }
    expected << "cert 2 #{PIN_SHA256}\n" unless expected.any? { |line| line.split.last == PIN_SHA256 }
    assert_equal expected.sort, filtered.lines.sort
    refute_equal baseline, filtered, 'host has no G4; filter regression cannot be exercised'
    invalid, _, status = Open3.capture3(probe, '99')
    filtered_invalid, _, filtered_status = Open3.capture3(
      {'DYLD_INSERT_LIBRARIES' => File.join(output, 'libow-nexon-trust.dylib')}, probe, '99')
    assert status.success?
    assert filtered_status.success?
    assert_equal invalid, filtered_invalid
    assert_includes Open3.capture2('/usr/bin/lipo', '-archs', File.join(output, 'libow-nexon-trust.dylib')).first, 'arm64'
    assert_includes Open3.capture2('/usr/bin/lipo', '-archs', File.join(output, 'libow-nexon-trust.dylib')).first, 'x86_64'
  end
end
