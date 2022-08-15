require 'json'
require 'salus/scanners/node_audit'
require 'salus/yarn_formatter'
require 'salus/semver'

# Yarn Audit scanner integration. Flags known malicious or vulnerable
# dependencies in javascript projects that are packaged with yarn.
# https://yarnpkg.com/en/docs/cli/audit

module Salus::Scanners
  class YarnAudit < NodeAudit
    class SemVersion < Gem::Version; end
    class ExportReportError < StandardError; end
    # the command was previously 'yarn audit --json', which had memory allocation issues
    # see https://github.com/yarnpkg/yarn/issues/7404
    LEGACY_YARN_AUDIT_COMMAND = 'yarn audit --no-color'.freeze
    LATEST_YARN_AUDIT_ALL_COMMAND = 'yarn npm audit --json'.freeze
    LATEST_YARN_AUDIT_PROD_COMMAND = 'yarn npm audit --environment'\
                  ' production --json'.freeze
    YARN_VERSION_COMMAND = 'yarn --version'.freeze
    BREAKING_VERSION = "2.0.0".freeze
    YARN_COMMAND = 'yarn'.freeze

    def should_run?
      @repository.yarn_lock_present?
    end

    def self.scanner_type
      Salus::ScannerTypes::DEPENDENCY
    end

    def run
      @vulns_w_paths = []
      if Gem::Version.new(version) >= Gem::Version.new(BREAKING_VERSION)
        handle_latest_yarn_audit
      else
        handle_legacy_yarn_audit
      end
    end

    def handle_latest_yarn_audit
      vulns = []
      dep_types = @config.fetch('exclude_groups', [])
      audit_command = if dep_types.include?('devDependencies')
                        LATEST_YARN_AUDIT_PROD_COMMAND
                      else
                        LATEST_YARN_AUDIT_ALL_COMMAND
                      end
      scan_depth = if @config.fetch('scan_depth', []).present?
                     '--' + @config.fetch('scan_depth').join('')
                   else
                     ''
                   end
      command = "#{audit_command} #{scan_depth}"
      shell_return = run_shell(command)
      excpts = fetch_exception_ids
      report_info(:ignored_cves, excpts)

      begin
        data = JSON.parse(shell_return.stdout)
      rescue JSON::ParserError
        err_msg = "YarnAudit: Could not parse JSON returned by #{command}"
        report_stderr(err_msg)
        report_error(err_msg)
        return []
      end

      data["advisories"].each do |advisory_id, advisory|
        if excpts.exclude?(advisory_id)
          dependency_of = advisory["findings"]&.first&.[]("paths")
          vulns.append({
                         "Package" => advisory.dig("module_name"),
                         "Patched in" => advisory.dig("patched_versions"),
                         "More info" => advisory.dig("url"),
                         "Severity" => advisory.dig("severity"),
                         "Title" => advisory.dig("title"),
                         "ID" => advisory_id.to_i,
                         "Dependency of" => if dependency_of.nil?
                                              advisory.dig("module_name")
                                            else
                                              dependency_of.join("")
                                            end
                       })
        end
      end
      return report_success if vulns.empty?

      vulns = combine_vulns(vulns)
      log(format_vulns(vulns))
      report_stdout(vulns.to_json)
      report_failure
    end

    def handle_legacy_yarn_audit
      command = "#{LEGACY_YARN_AUDIT_COMMAND} #{scan_deps}"
      shell_return = run_shell(command)

      excpts = fetch_exception_ids.map(&:to_i)
      report_info(:ignored_cves, excpts)
      return report_success if shell_return.success?

      stdout_lines = shell_return.stdout.split("\n")
      table_start_pos = stdout_lines.index { |l| l.start_with?("┌─") && l.end_with?("─┐") }
      table_end_pos = stdout_lines.rindex { |l| l.start_with?("└─") && l.end_with?("─┘") }

      # if no table in output
      if table_start_pos.nil? || table_end_pos.nil?
        report_error(shell_return.stderr, status: shell_return.status)
        report_stderr(shell_return.stderr)
        return report_failure
      end

      table_lines = stdout_lines[table_start_pos..table_end_pos]
      # lines contain 1 or more vuln tables

      vulns = parse_output(table_lines)
      @vulns_w_paths = deep_copy_wo_paths(vulns)
      vulns.each { |vul| vul.delete('Path') }
      vuln_ids = vulns.map { |v| v['ID'] }
      report_info(:vulnerabilities, vuln_ids.uniq)

      vulns.reject! { |v| excpts.include?(v['ID']) }
      # vulns were all whitelisted
      return report_success if vulns.empty?

      chdir = File.expand_path(@repository&.path_to_repo)

      Salus::YarnLock.new(File.join(chdir, 'yarn.lock')).add_line_number(vulns)

      auto_fix = @config.fetch("auto_fix", false)
      run_auto_fix(generate_fix_feed) if auto_fix

      vulns = combine_vulns(vulns)
      log(format_vulns(vulns))
      report_stdout(vulns.to_json)
      report_failure
    end

    def generate_fix_feed
      actions = []
      grouped_vulns = @vulns_w_paths.group_by { |h| [h["Package"], h["Patched in"]] }
      grouped_vulns.each do |key, values|
        name = key.first
        patch = key.last
        resolves = []
        values.each do |value|
          resolves.append({
                            "id": value["ID"],
                  "path": value["Path"],
                  "dev": false,
                    "optional": false,
                    "bundled": false
                          })
        end
        actions.append({
                         "action": "update",
          "module": name,
          "target": patch,
          "resolves": resolves
                       })
      end
      actions
    end

    # Auto Fix will try to attempt direct and indirect dependencies
    # Direct dependencies are found in package.json
    # Indirect dependencies are found in yarn.lock
    # By default, it will skip major version bumps
    def run_auto_fix(feed)
      fix_indirect_dependency(feed)
      fix_direct_dependency(feed)
    rescue StandardError => e
      report_error("An error occurred while auto-fixing vulnerabilities: #{e}, #{e.backtrace}")
    end

    def fix_direct_dependency(feed)
      @packages = JSON.parse(@repository.package_json)
      feed.each do |vuln|
        patch = vuln[:target]
        resolves = vuln[:resolves]
        package = vuln[:module]
        resolves.each do |resolve|
          if !patch.nil? && patch != "No patch available" && package == resolve[:path]
            update_direct_dependency(package, patch)
          end
        end
      end
      write_auto_fix_files('package-autofixed.json', JSON.pretty_generate(@packages))
    end

    def fix_indirect_dependency(feed)
      @parsed_yarn_lock = Salus::YarnLockfileFormatter.new(@repository.yarn_lock).format
      subparent_to_package_mapping = []

      feed.each do |vuln|
        patch = vuln[:target]
        resolves = vuln[:resolves]
        package = vuln[:module]
        resolves.each do |resolve|
          if !patch.nil? && patch != "No patch available" && package != resolve[:path]
            block = create_subparent_to_package_mapping(resolve[:path])
            if block.key?(:key)
              block[:patch] = patch
              subparent_to_package_mapping.append(block)
            end
          end
        end
      end
      parts = @repository.yarn_lock.split(/^\n/)
      parts = update_package_definition(subparent_to_package_mapping, parts)
      parts = update_sub_parent_resolution(subparent_to_package_mapping, parts)
      # TODO: Run clean up task
      write_auto_fix_files('yarn-autofixed.lock', parts.join("\n"))
    end

    # In yarn.lock, we attempt to update yarn.lock entries for the package
    def update_package_definition(blocks, parts)
      blocks.uniq { |hash| hash.values_at(:prev, :key, :patch) }
      group_updates = blocks.group_by { |h| [h[:prev], h[:key]] }
      group_updates.each do |updates, versions|
        updates = updates.last
        vulnerable_package_info = get_package_info(updates)
        list_of_versions_available = vulnerable_package_info["data"]["versions"]
        version_to_update_to = Salus::SemanticVersion.select_upgrade_version(
          versions.first[:patch], list_of_versions_available
        )
        package_name = if updates.starts_with? "@"
                         updates.split("@", 2).first
                       else
                         updates.split("@").first
                       end
        if !version_to_update_to.nil?
          fixed_package_info = get_package_info(package_name, version_to_update_to)
          unless fixed_package_info.nil?
            updated_version = "version " + '"' + version_to_update_to + '"'
            updated_resolved = "resolved " + '"' + fixed_package_info["data"]["dist"]["tarball"] \
              + "#" + fixed_package_info["data"]["dist"]["shasum"] + '"'
            updated_integrity = "integrity " + fixed_package_info['data']['dist']['integrity']
            updated_name = package_name + "@^" + version_to_update_to
            parts.each_with_index do |part, index|
              current_v = parts[index].match(/(version .*)/)
              version_string = current_v.to_s.tr('"', "").tr("version ", "")
              if part.include?(updates) && !is_major_bump(
                version_string, version_to_update_to
              )
                parts[index].sub!(updates, updated_name)
                parts[index].sub!(/(version .*)/, updated_version)
                parts[index].sub!(/(resolved .*)/, updated_resolved)
                parts[index].sub!(/(integrity .*)/, updated_integrity)
              end
            end
          end
        end
      end
      parts
    end

    # In yarn.lock, we attempt to resolve sub parent of the affected package to
    # new updated package definition.
    def update_sub_parent_resolution(blocks, parts)
      blocks.uniq { |hash| hash.values_at(:prev, :key, :patch) }
      group_appends = blocks.group_by { |h| [h[:prev], h[:key]] }
      group_appends.each do |pair, patch|
        source = pair.first
        target = if pair.last.starts_with? "@"
                   pair.last.split("@", 2).first
                 else
                   pair.last.split("@").first
                 end

        vulnerable_package_info = get_package_info(target)
        list_of_versions_available = vulnerable_package_info["data"]["versions"]
        version_to_update_to = Salus::SemanticVersion.select_upgrade_version(
          patch.first[:patch], list_of_versions_available
        )
        if !version_to_update_to.nil?

          update_version_string = "^" + version_to_update_to
          parts.each_with_index do |part, index|
            match = part.match(/(#{target} .*)/)
            if part.include?(source) && part.include?(target) &&
                !is_major_bump(match.to_s, version_to_update_to)
              match = part.match(/(#{target} .*)/)
              replace = match.to_s.split(" ").first + ' "^' + version_to_update_to + '"'
              part.sub!(/(#{target} .*)/, replace)
              parts[index] = part
            end
          end
          section = @parsed_yarn_lock[source]
          section["dependencies"][target] = update_version_string
          @parsed_yarn_lock[source] = section
        end
      end
      parts
    end

    def update_direct_dependency(package, patched_version_range)
      if patched_version_range.match(Salus::SemanticVersion::SEMVER_RANGE_REGEX).nil?
        report_error("Found unexpected: patched version range: #{patched_version_range}")
        return
      end

      vulnerable_package_info = get_package_info(package)
      list_of_versions = vulnerable_package_info.dig("data", "versions")

      if list_of_versions.nil?
        report_error(
          "#yarn info command did not provide a list of available package versions"
        )
        return
      end

      patched_version = Salus::SemanticVersion.select_upgrade_version(
        patched_version_range,
        list_of_versions
      )

      if !patched_version.nil?
        %w[dependencies resolutions devDependencies].each do |package_section|
          if !@packages.dig(package_section, package).nil?
            current_version = @packages[package_section][package]
            if !is_major_bump(current_version, patched_version)
              @packages[package_section][package] = "^#{patched_version}"
            end
          end
        end
      end
    end

    def version
      shell_return = run_shell(YARN_VERSION_COMMAND)
      # stdout looks like "1.22.0\n"
      shell_return.stdout&.strip
    end

    def self.supported_languages
      ['javascript']
    end

    private

    def parse_output(lines)
      vulns = Set.new

      i = 0
      while i < lines.size
        if lines[i].start_with?("┌─") && lines[i].end_with?("─┐")
          vuln = {}
        elsif lines[i].start_with? "│ "
          line_split = lines[i].split("│")
          curr_key = line_split[1].strip
          val = line_split[2].strip
          if curr_key != ""
            vuln[curr_key] = val
            prev_key = curr_key
          else
            vuln[prev_key] += ' ' + val
          end
        elsif lines[i].start_with?("└─") && lines[i].end_with?("─┘")
          vulns.add(vuln)
        end
        i += 1
      end

      vulns = vulns.to_a
      vulns.each { |vln| normalize_vuln(vln) }.sort { |a, b| a['ID'] <=> b['ID'] }
    end

    def scan_deps
      dep_types = @config.fetch('exclude_groups', [])

      return '' if dep_types.empty?

      if dep_types.include?('devDependencies') &&
          dep_types.include?('dependencies') &&
          dep_types.include?('optionalDependencies')
        report_error("No dependencies were scanned!")
        return ''
      elsif dep_types.include?('devDependencies') && dep_types.include?('dependencies')
        report_warn(:scanner_misconfiguration, "Scanning only optionalDependencies!")
      end

      command = ' --groups '
      command << 'dependencies ' unless dep_types.include?('dependencies')
      command << 'devDependencies ' unless dep_types.include?('devDependencies')
      command << 'optionalDependencies ' unless dep_types.include?('optionalDependencies')
    end

    def find_nested_hash_value(obj, key)
      if obj.respond_to?(:key?) && obj.key?(key)
        obj[key]
      elsif obj.respond_to?(:each)
        r = nil
        obj.find { |*a| r = find_nested_hash_value(a.last, key) }
        r
      end
    end

    # severity and vuln title in the yarn output looks like
    # | low           | Prototype Pollution                                          |
    # which are stored in the vuln hash as "low" ==> "Prototype Pollution"
    # need to update that to
    #     1) "severity" => "low"
    #     2) "title" => "Prototype Pollution"
    #
    # Also, add a separate id field
    def normalize_vuln(vuln)
      sev_levels = %w[info low moderate high critical]

      sev_levels.each do |sev|
        if vuln[sev]
          vuln['Severity'] = sev
          vuln['Title'] = vuln[sev]
          vuln.delete(sev)
          break
        end
      end

      # "More info" looks like https://www.npmjs.com/advisories/1179
      # need to extract the id at the end
      id = vuln["More info"].split("https://www.npmjs.com/advisories/")[1]
      vuln['ID'] = id.to_i
    end

    def combine_vulns(vulns)
      uniq_vulns = {} # each key is uniq id

      vulns.each do |vul|
        id = vul['ID']
        if uniq_vulns[id]
          uniq_vulns[id]['Dependency of'].push vul['Dependency of']
        else
          uniq_vulns[id] = vul
          uniq_vulns[id]['Dependency of'] = [uniq_vulns[id]['Dependency of']]
        end
      end

      vulns = uniq_vulns.values
      vulns.each do |vul|
        vul['Dependency of'] = vul['Dependency of'].sort.join(', ')
      end
      vulns
    end

    def create_subparent_to_package_mapping(path)
      section = {}
      packages = path.split(" > ")
      packages.each_with_index do |package, index|
        break if index == packages.length - 1

        section = if index.zero?
                    find_section_by_name(package, packages[index + 1])
                  else
                    find_section_by_name_and_version(section[:key], packages[index + 1])
                  end
      end
      section
    end

    def find_section_by_name(name, next_package)
      @parsed_yarn_lock.each do |key, array|
        if key.starts_with? "#{name}@"
          %w[dependencies optionalDependencies].each do |section|
            if array[section]&.[](next_package)
              value = array.dig(section, next_package)
              return { "prev": key, "key": "#{next_package}@#{value}" }
            end
          end
        end
      end
      {}
    end

    def find_section_by_name_and_version(name, next_package)
      @parsed_yarn_lock.each do |key, array|
        if key == name
          %w[dependencies optionalDependencies].each do |section|
            if array[section]&.[](next_package)
              value = array.dig(section, next_package)
              return { "prev": key, "key": "#{next_package}@#{value}" }
            end
          end
        end
      end
      {}
    end

    def get_package_info(package, version = nil)
      info = if version.nil?
               run_shell("yarn info #{package} --json")
             else
               run_shell("yarn info #{package}@#{version} --json")
             end
      JSON.parse(info.stdout)
    rescue StandardError
      report_error("#{info} did not return JSON")
      nil
    end

    def write_auto_fix_files(file, content)
      Dir.chdir(@repository.path_to_repo) do
        File.open(file, 'w') { |f| f.write(content) }
        err_msg = "\n***** WARNING: autofix:true but cannot find #{file}"
        report_error(err_msg) if !File.exist?(file)
      end
    end

    def deep_copy_wo_paths(vulns)
      vuln_list = []
      vulns.each do |vuln|
        vt = {}
        vuln.each { |k, v| vt[k] = v }
        vuln_list.push vt
      end
      vuln_list
    end

    def is_major_bump(current, updated)
      current.gsub(/[^0-9.]/, "")
      current_v = current.split('.').map(&:to_i)
      updated.sub(/[^0-9.]/, "")
      updated_v = updated.split('.').map(&:to_i)
      return true if updated_v.first > current_v.first

      false
    end

    def format_vulns(vulns)
      str = ""
      vulns.each do |vul|
        vul.each do |k, v|
          str += "#{k}: #{v}\n"
        end
        str += "\n"
      end
      str
    end
  end
end
