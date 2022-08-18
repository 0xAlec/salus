require 'salus/yarn_formatter'
require 'salus/autofixers/base'

module Salus::Autofixers
  class YarnAuditV2 < Base
    def initialize(path_to_repo)
      @path_to_repo = path_to_repo
    end

    # Auto Fix will try to attempt direct and indirect dependencies
    # Direct dependencies are found in package.json
    # Indirect dependencies are found in yarn.lock
    # By default, it will skip major version bumps
    def run_auto_fix(feed, path_to_repo, package_json, yarn_lock)
      fix_indirect_dependency(feed, yarn_lock, path_to_repo)
      fix_direct_dependency(feed, package_json, path_to_repo)
    end
    # rescue StandardError => e
    #   error_msg = "An error occurred while auto-fixing vulnerabilities: #{e}, #{e.backtrace}"
    #   raise AutofixError, error_msg
    # end

    def fix_direct_dependency(feed, package_json, path_to_repo)
      packages = JSON.parse(package_json)
      feed.each do |vuln|
        patch = vuln["target"]
        resolves = vuln["resolves"]
        package = vuln["module"]
        resolves.each do |resolve|
          if !patch.nil? && patch != "No patch available" && package == resolve["path"]
            update_direct_dependency(package, patch, packages)
          end
        end
      end
      write_auto_fix_files(path_to_repo, 'package-autofixed.json', JSON.dump(packages))
    end

    def fix_indirect_dependency(feed, yarn_lock, path_to_repo)
      parsed_yarn_lock = Salus::YarnLockfileFormatter.new(yarn_lock).format
      subparent_to_package_mapping = []

      feed.each do |vuln|
        puts vuln
        patch = vuln["target"]
        resolves = vuln["resolves"]
        package = vuln["module"]
        resolves.each do |resolve|
          if !patch.nil? && patch != "No patch available" && package != resolve["path"]
            block = create_subparent_to_package_mapping(parsed_yarn_lock, resolve["path"])
            if block.key?(:key)
              block[:patch] = patch
              subparent_to_package_mapping.append(block)
            end
          end
        end
      end
    #   parts = yarn_lock.split(/^\n/)
    #   parts = update_package_definition(subparent_to_package_mapping, parts)
    #   parts = update_sub_parent_resolution(subparent_to_package_mapping, parts, parsed_yarn_lock)
      # TODO: Run clean up task
    #   write_auto_fix_files(path_to_repo, 'yarn-autofixed.lock', parts.join("\n"))
    end

    # In yarn.lock, we attempt to update yarn.lock entries for the package
    def update_package_definition(blocks, parts)
      blocks.uniq { |hash| hash.values_at(:prev, :key, :patch) }
      group_updates = blocks.group_by { |h| [h[:prev], h[:key]] }
      group_updates.each do |updates, versions|
        updates = updates.last
        vulnerable_package_info = get_package_info(updates)
        list_of_versions_available = vulnerable_package_info["versions"]
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
            updated_resolved = "resolved " + '"' + fixed_package_info["dist"]["tarball"] \
              + "#" + fixed_package_info["dist"]["shasum"] + '"'
            updated_integrity = "integrity " + fixed_package_info['dist']['integrity']
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

    def get_package_info(package, version = nil)
      info = if version.nil?
               run_shell("yarn npm info #{package} --json", chdir: File.expand_path(@path_to_repo))
             else
               run_shell(
                 "yarn npm info #{package}@#{version} --json",
                 chdir: File.expand_path(@path_to_repo)
               )
             end
      JSON.parse(info.stdout)
    rescue StandardError
      nil
    end

    def is_major_bump(current, updated)
      current.gsub(/[^0-9.]/, "")
      current_v = current.split('.').map(&:to_i)
      updated.sub(/[^0-9.]/, "")
      updated_v = updated.split('.').map(&:to_i)
      return true if updated_v.first > current_v.first

      false
    end

    # In yarn.lock, we attempt to resolve sub parent of the affected package to
    # new updated package definition.
    def update_sub_parent_resolution(blocks, parts, parsed_yarn_lock)
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
            if part.include?(source) && !match.nil? &&
                !is_major_bump(match.to_s, version_to_update_to)
              match = part.match(/(#{target} .*)/)
              replace = match.to_s.split(" ").first + ' "^' + version_to_update_to + '"'
              part.sub!(/(#{target} .*)/, replace)
              parts[index] = part
            end
          end
          section = parsed_yarn_lock[source]
          section["dependencies"][target] = update_version_string
          parsed_yarn_lock[source] = section
        end
      end
      parts
    end

    def create_subparent_to_package_mapping(parsed_yarn_lock, path)
      section = {}
      packages = path.split(">")
      packages.each_with_index do |package, index|
        break if index == packages.length - 1

        section = if index.zero?
                    puts find_section_by_name(parsed_yarn_lock, package, packages[index + 1])
                    find_section_by_name(parsed_yarn_lock, package, packages[index + 1])
                  else
                    find_section_by_name_and_version(
                      parsed_yarn_lock,
                      section[:key],
                      packages[index + 1]
                    )
                  end
      end
      puts section
      section
    end

    def find_section_by_name(parsed_yarn_lock, name, next_package)
      parsed_yarn_lock.each do |key, array|
        if key.starts_with? "#{name}@"
          %w[dependencies optionalDependencies].each do |section|
            if array[section]&.[](next_package)
              value = array.dig(section, next_package)
              return { "prev": key, "key": "#{next_package}@npm:#{value}" }
            end
          end
        end
      end
      {}
    end

    def find_section_by_name_and_version(parsed_yarn_lock, name, next_package)
      parsed_yarn_lock.each do |key, array|
        if key == name
          %w[dependencies peerDependencies].each do |section|
            if array[section]&.[](next_package)
              value = array.dig(section, next_package)
              return { "prev": key, "key": "#{next_package}@npm:#{value}" }
            end
          end
        end
      end
      {}
    end

    def update_direct_dependency(package, patched_version_range, packages)
      if patched_version_range.match(Salus::SemanticVersion::SEMVER_RANGE_REGEX).nil?
        raise AutofixError, "Found unexpected: patched version range: #{patched_version_range}"
      end

      vulnerable_package_info = get_package_info(package)
      list_of_versions = vulnerable_package_info.dig("data", "versions")

      if list_of_versions.nil?
        error_msg = "#yarn info command did not provide a list of available package versions"
        raise AutofixError, error_msg
      end

      patched_version = Salus::SemanticVersion.select_upgrade_version(
        patched_version_range,
        list_of_versions
      )

      if !patched_version.nil?
        %w[dependencies resolutions devDependencies].each do |package_section|
          if !packages.dig(package_section, package).nil?
            current_version = packages[package_section][package]
            if !is_major_bump(current_version, patched_version)
              packages[package_section][package] = "^#{patched_version}"
            end
          end
        end
      end
    end
  end
end
