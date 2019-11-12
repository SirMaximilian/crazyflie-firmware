require 'yaml'
require 'fileutils'
require './vendor/unity/auto/unity_test_summary'
require './vendor/unity/auto/generate_test_runner'
require './vendor/unity/auto/colour_reporter'

module RakefileHelpers

  C_EXTENSION = '.c'

  def load_configuration(config_file)
    $cfg_file = config_file
    $cfg = YAML.load(File.read($cfg_file))
    $colour_output = false unless $cfg['colour']
  end

  def configure_clean
    CLEAN.include($cfg['compiler']['build_path'] + '*.*') unless $cfg['compiler']['build_path'].nil?
  end

  def configure_toolchain(config_file=DEFAULT_CONFIG_FILE)
    config_file += '.yml' unless config_file =~ /\.yml$/
    load_configuration(config_file)
    configure_clean
  end

  def get_unit_test_files
    path = $cfg['compiler']['unit_tests_path'] + 'test_*' + C_EXTENSION
    path.gsub!(/\\/, '/')
    FileList.new(path)
  end

  def get_local_include_dirs
    include_dirs = $cfg['compiler']['includes']['items'].dup
    include_dirs.delete_if {|dir| dir.is_a?(Array)}
    return include_dirs
  end

  def extract_headers(filename)
    includes = []
    lines = File.readlines(filename)
    lines.each do |line|
      # Check if there is an include that we should add
      m = line.match(/^\s*#include\s+\"\s*(.+\.[hH])\s*\"/)
      if not m.nil?
        if !line.include? "@NO_MODULE"
          includes << m[1]
        end
      end

      # Check if there is a module to add based on an annotation
      m = line.match(/^\/\/\s*@MODULE\s+\"\s*(.+\.)[cC]\s*\"/)
      if not m.nil?
        # Fake that it is a .h file
        h_file_name = m[1] + 'h'
        includes << h_file_name
      end
    end
    return includes
  end

  def find_source_file(header, paths)
    find_file(header.ext(C_EXTENSION), paths)
  end

  def find_file(name, paths)
    paths.each do |dir|
      src_file = dir + name
      if (File.exists?(src_file))
        return src_file
      end
    end
    return nil
  end

  def tackit(strings)
    case(strings)
      when Array
        "\"#{strings.join}\""
      when /^-/
        strings
      when /\s/
        "\"#{strings}\""
      else
        strings
    end
  end

  def squash(prefix, items)
    result = ''
    items.each { |item| result += " #{prefix}#{tackit(item)}" }
    return result
  end

  def build_compiler_fields(extra_options=[])
    command  = tackit($cfg['compiler']['path'])
    if $cfg['compiler']['defines']['items'].nil?
      defines  = ''
    else
      defines  = squash($cfg['compiler']['defines']['prefix'], $cfg['compiler']['defines']['items'])
    end
    options  = squash('', $cfg['compiler']['options'] + extra_options)
    includes = squash($cfg['compiler']['includes']['prefix'], $cfg['compiler']['includes']['items'])
    includes = includes.gsub(/\\ /, ' ').gsub(/\\\"/, '"').gsub(/\\$/, '') # Remove trailing slashes (for IAR)
    return {:command => command, :defines => defines, :options => options, :includes => includes}
  end

  def compile(file, defines=[], extra_options=[])
    compiler = build_compiler_fields(extra_options)
    cmd_str  = "#{compiler[:command]}#{compiler[:defines]}#{compiler[:options]}#{compiler[:includes]} #{file} " +
               "#{$cfg['compiler']['object_files']['prefix']}#{$cfg['compiler']['object_files']['destination']}"
    obj_file = "#{File.basename(file, C_EXTENSION)}#{$cfg['compiler']['object_files']['extension']}"
    execute(cmd_str + obj_file)
    return obj_file
  end

  def build_linker_fields
    command  = tackit($cfg['linker']['path'])
    if $cfg['linker']['options'].nil?
      options  = ''
    else
      options  = squash('', $cfg['linker']['options'])
    end
    if ($cfg['linker']['includes'].nil? || $cfg['linker']['includes']['items'].nil?)
      includes = ''
    else
      includes = squash($cfg['linker']['includes']['prefix'], $cfg['linker']['includes']['items'])
    end
    includes = includes.gsub(/\\ /, ' ').gsub(/\\\"/, '"').gsub(/\\$/, '') # Remove trailing slashes (for IAR)
    return {:command => command, :options => options, :includes => includes}
  end

  def link_it(exe_name, obj_list)
    linker = build_linker_fields
    cmd_str = "#{linker[:command]}#{linker[:includes]} " +
      (obj_list.map{|obj|"#{$cfg['linker']['object_files']['path']}#{obj} "}).join +
      $cfg['linker']['bin_files']['prefix'] + ' ' +
      $cfg['linker']['bin_files']['destination'] +
      exe_name + $cfg['linker']['bin_files']['extension'] + " #{linker[:options]}"
    execute(cmd_str)
  end

  def build_simulator_fields
    return nil if $cfg['simulator'].nil?
    if $cfg['simulator']['path'].nil?
      command = ''
    else
      command = (tackit($cfg['simulator']['path']) + ' ')
    end
    if $cfg['simulator']['pre_support'].nil?
      pre_support = ''
    else
      pre_support = squash('', $cfg['simulator']['pre_support'])
    end
    if $cfg['simulator']['post_support'].nil?
      post_support = ''
    else
      post_support = squash('', $cfg['simulator']['post_support'])
    end
    return {:command => command, :pre_support => pre_support, :post_support => post_support}
  end

  def execute(command_string, logOutput: true)
    report(command_string) if $logCmd
    output = `#{command_string}`.chomp
    report(output) if (logOutput && !output.nil? && (output.length > 0))
    if $?.exitstatus != 0
      raise "Command failed. (Returned #{$?.exitstatus})"
    end
    return output
  end

  def report_summary
    summary = UnityTestSummary.new
    summary.set_root_path(HERE)
    results_glob = "#{$cfg['compiler']['build_path']}*.test*"
    results_glob.gsub!(/\\/, '/')
    results = Dir[results_glob]
    summary.set_targets(results)
    report summary.run
    raise "There were failures" if (summary.failures > 0)
  end

  def parse_and_run_tests(args)
    defines = find_defines_in_args(args)
    test_files = find_test_files_in_args(args)
    output_style = find_output_style_in_args(args)

    # No file names found in the args, find all files that are unit test files
    if test_files.length == 0
      test_files = exclude_test_files(get_unit_test_files(), defines)
    end

    run_tests(test_files, defines, output_style)
  end

  def run_tests(test_files, defines, output_style)
    report 'Running system tests...'

    # Tack on TEST define for compiling unit tests
    load_configuration($cfg_file)
    test_defines = ['TEST']
    $cfg['compiler']['defines']['items'] = [] if $cfg['compiler']['defines']['items'].nil?
    $cfg['compiler']['defines']['items'] << 'TEST'
    $cfg['compiler']['defines']['items'].concat defines

    # Supress logging of commands and all warningns in minimalistic output style
    $logCmd = true
    puts 'output_style ' + output_style.to_s
    if output_style.include?('min')
      $cfg['compiler']['options'] << '-w'
      $logCmd = false
    end

    include_dirs = get_local_include_dirs

    # Build and execute each unit test
    test_files.each do |test|
      obj_list = []

      # Detect dependencies and build required modules
      header_list = extract_headers(test) + ['cmock.h']

      header_list.each do |header|

        #create mocks if needed
        if (header =~ /mock_/)
          include_name = header.gsub('mock_','')
          header_file = find_file(include_name, include_dirs)

          require "./vendor/cmock/lib/cmock.rb"
          @cmock ||= CMock.new($cfg_file)
          @cmock.setup_mocks([header_file])
        end

      end

      #compile all mocks
      header_list.each do |header|
        #compile source file header if it exists
        src_file = find_source_file(header, include_dirs)
        if !src_file.nil?
          obj_list << compile(src_file, test_defines)
        end
      end

      # build libs
      lib_annotations = read_lib_annotations(test)
      obj_list += add_lib_source_files(lib_annotations, test_defines)

      # Build the test runner (generate if configured to do so)
      test_base = File.basename(test, C_EXTENSION)
      runner_name = test_base + '_Runner.c'
      if $cfg['compiler']['runner_path'].nil?
        runner_path = $cfg['compiler']['build_path'] + runner_name
        test_gen = UnityTestRunnerGenerator.new($cfg_file)
        test_gen.run(test, runner_path)
      else
        runner_path = $cfg['compiler']['runner_path'] + runner_name
      end

      obj_list << compile(runner_path, test_defines)

      # Build the test module
      obj_list << compile(test, test_defines)

      # Link the test executable
      link_it(test_base, obj_list)

      # Execute unit test and generate results file
      simulator = build_simulator_fields
      executable = $cfg['linker']['bin_files']['destination'] + test_base + $cfg['linker']['bin_files']['extension']
      if simulator.nil?
        cmd_str = executable
      else
        cmd_str = "#{simulator[:command]} #{simulator[:pre_support]} #{executable} #{simulator[:post_support]}"
      end
      output = execute(cmd_str)
      test_results = $cfg['compiler']['build_path'] + test_base
      if output.match(/OK$/m).nil?
        test_results += '.testfail'
      else
        test_results += '.testpass'
      end
      File.open(test_results, 'w') { |f| f.print output }
    end
  end

  def build_application(main)

    report "Building application..."

    obj_list = []
    load_configuration($cfg_file)
    main_path = $cfg['compiler']['source_path'] + main + C_EXTENSION

    # Detect dependencies and build required modules
    include_dirs = get_local_include_dirs
    extract_headers(main_path).each do |header|
      src_file = find_source_file(header, include_dirs)
      if !src_file.nil?
        obj_list << compile(src_file)
      end
    end

    # Build the main source file
    main_base = File.basename(main_path, C_EXTENSION)
    obj_list << compile(main_path)

    # Create the executable
    link_it(main_base, obj_list)
  end

  def find_test_files_in_args(args)
    key = 'FILES='
    args.each do |arg|
      if arg.start_with?(key)
        return arg[(key.length)..-1].split(' ')
      end
    end
  end

  def find_output_style_in_args(args)
    key = 'UNIT_TEST_STYLE='
    args.each do |arg|
      if arg.start_with?(key)
        return arg[(key.length)..-1].split(' ')
      end
    end
  end

  # Parse the arguments and find all defines that are passed in on the command line
  # Defines are part of compiler flags and start with -D, for instance -DMY_DEFINE
  # All compiler flags are passed in as one string
  def find_defines_in_args(args)
    key = 'DEFINES='
    args.each do |arg|
      if arg.start_with?(key)
        return extract_defines(arg[(key.length)..-1])
      end
    end
  end

  def extract_defines(arg)
    arg.split(' ').select {|part| part.start_with?('-D')}.map {|flag| flag[2..-1]}
  end

  def exclude_test_files(files, defines)
    files.select do |file|
      !annotation_ignore_file?(file, defines)
    end
  end


  # WARNING This implementation is fairly brittle. Basically only intended for cases such as
  # // @IGNORE_IF_NOT PLATFORM_CF2
  # Ignores values of defines, so this would fail and keep the file
  # param to gradle: -DMYDEFINE=0
  # // @IGNORE_IF_NOT MYDEFINE
  def annotation_ignore_file?(file, defines)
    ignore_str = '@IGNORE_IF_NOT'

    File.foreach( file ) do |line|
      if line.include? ignore_str
        tokens = line.split(' ')
        index = tokens.index ignore_str

        if tokens.length >= (index + 2)
          condition = tokens[index + 1]
          conditionIsMet = defines.detect {|define| define == condition}
          if !conditionIsMet
            return true
          end
        end
      end
    end

    return false
  end

  # Annotation to add files for libraries
  # When this annotation is used source files for libs are added to the build
  # with the unit test so that they can be called and does not have to be
  # replaced by mocks.
  def read_lib_annotations(file)
    annotation_str = '@BUILD_LIB'
    libs = []

    File.foreach( file ) do |line|
      if line.include? annotation_str
        tokens = line.split(' ')
        index = tokens.index annotation_str

        if tokens.length >= (index + 2)
          libs << tokens[index + 1]
        end
      end
    end

    libs
  end

  def add_lib_source_files(libs, test_defines)
    obj_list = []
    libs.each do |lib|
      puts 'Adding lib ' + lib

      files = $cfg['compiler']['libs'][lib]['files']
      extra_options = $cfg['compiler']['libs'][lib]['extra_options']
      files.each do |src_file|
        obj_list << compile(src_file, test_defines, extra_options=extra_options)
      end
    end

    obj_list
  end
end
