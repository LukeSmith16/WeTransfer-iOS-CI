# rubocop:disable Layout/LineLength

require 'uri'

desc 'Runs tests for a specific package'
desc ''
desc '#### Options'
desc ' * **`package_name`**: The name of the package to test'
desc ' * **`package_path`**: The path to the package'
desc ''
lane :test_package do |options|
  UI.abort_with_message! "Package path is missing" unless options[:package_path]
  UI.abort_with_message! "Package name is missing" unless options[:package_name]
  test_project(options)
end

desc 'Runs tests for an external project'
desc ''
desc '#### Options'
desc " * **`scheme`**: The project's scheme"
desc ' * **`project_path`**: The path to the project'
desc ' * **`project_name`**: The name of the project'
desc ' * **`destination`**: ..'
lane :test_project do |options|
  #clear_derived_data

  # Remove any leftover reports before running so local runs won't fail due to an existing file.
  sh("rm -rf #{ENV['PWD']}/build/reports") unless is_running_on_CI(options)

  # Set timeout to prevent xcodebuild -list -project to take to much retries.
  ENV['FASTLANE_XCODEBUILD_SETTINGS_TIMEOUT'] = '30'
  ENV['FASTLANE_XCODE_LIST_TIMEOUT'] = '30'

  begin
    device = options[:device] || 'iPhone 14'

    if options[:package_path].nil?
      project_path = "#{options[:project_path]}#{options[:project_name]}.xcodeproj"
    end

    sourcePackagesDir = "#{ENV['PWD']}/.spm-build"

    scan(
      scheme: options[:scheme] || options[:package_name],
      project: project_path,
      device: device,
      destination: options[:destination],
      code_coverage: true,
      disable_concurrent_testing: true, # As of 27th October 2021, this seems to not be working anymore. We need `parallel-testing-enabled NO` instead.
      fail_build: false,
      skip_slack: true,
      output_types: '',
      #disable_xcpretty: true, # [11:59:03]: Using deprecated option: '--disable_xcpretty' (Use `output_style: 'raw'` instead)
      suppress_xcode_output: false,
      buildlog_path: ENV['BITRISE_DEPLOY_DIR'],
      prelaunch_simulator: true,
      xcargs: "-clonedSourcePackagesDirPath #{sourcePackagesDir} -parallel-testing-enabled NO -retry-tests-on-failure -test-iterations 3",
      include_simulator_logs: false, # Needed for this: https://github.com/fastlane/fastlane/issues/8909
      result_bundle: true,
      output_directory: "#{ENV['PWD']}/build/reports/",
      derived_data_path: "#{ENV['PWD']}/build/derived_data", # Set buildlog and derived data path to fix permission issues on Bitrise
      package_path: options[:package_path],
      build_for_testing: options.fetch(:build_for_testing, nil),
      test_without_building: options.fetch(:test_without_building, nil),
      disable_package_automatic_updates: true, # Makes xcodebuild -showBuildSettings more reliable too.
      skip_package_dependencies_resolution: options.fetch(:disable_automatic_package_resolution, false)
    )
  rescue StandardError => e
    if options.fetch(:raise_exception_on_failure, false)
      raise e
    else
      UI.important("Tests failed for #{e}")
    end
  end
end

desc 'Create a release from a tag triggered CI run'
lane :release_from_tag do
  # Get the latest tag, which is the new release that triggered this lane.
  sh('git fetch --tags origin master --no-recurse-submodules -q')

  latest_tag = ENV['BITRISE_GIT_TAG']

  # Create a release branch
  sh "git branch release/#{latest_tag} origin/master"
  sh "git checkout release/#{latest_tag}"
  sh "git merge -X theirs #{latest_tag}"

  release_output = sh('mint run --silent gitbuddy release -c "../Changelog.md"')
  release_url = URI.extract(release_output).find { |url| url.include? 'releases/tag' }
  puts "Created release with URL: #{release_url}"

  # Run only if there's a podspec to update
  if Dir['../*.podspec'].any?
    # Update the podspec. It finds the .podspec automatically in the current folder.
    version_bump_podspec(version_number: latest_tag)

    begin
      # Push the podspec to trunk
      pod_push
    rescue StandardError => e
      UI.important("Pod push failed: #{e}")
    end
  end

  # Push the changes to the branch
  sh('git commit -a -m "Created a new release"')
  sh("git push origin release/#{latest_tag}")

  # Create a pull request for master to include the updated Changelog.md and podspec
  create_pull_request(
    api_token: ENV['DANGER_GITHUB_API_TOKEN'],
    repo: git_repository_name,
    title: "Merge release #{latest_tag} into master",
    base: 'master', # The branch to merge the changes into.
    body: "Containing all the changes for our [**#{latest_tag} Release**](#{release_url})."
  )
end

desc 'Unhide dev dependencies for danger'
lane :unhide_spm_package_dev_dependencies do
  text = File.read('../Package.swift')
  new_contents = text.gsub('// dev ', '')

  # To write changes to the file, use:
  File.open('../Package.swift', 'w') { |file| file.puts new_contents }
end

desc 'Get all changed files in the current PR'
desc 'Requires that the enviroment contains a Danger GitHub API token `DANGER_GITHUB_API_TOKEN`'
desc ''
desc '#### Options'
desc ' * **`pr_id`**: The identifier of the PR that contains the changes.'
desc ''
lane :changed_files_in_pr do |options|
  origin_name = git_repository_name.split('/')
  organisation = origin_name[0]
  repository = origin_name[1]

  if options[:pr_id].nil?
    raise 'Missing PR ID input'
  elsif ENV['DANGER_GITHUB_API_TOKEN'].nil?
    raise "Missing 'DANGER_GITHUB_API_TOKEN' environment variable"
  end

  puts "Fetching changed files for PR #{options[:pr_id]} using token ...#{ENV['DANGER_GITHUB_API_TOKEN'].chars.last(5).join}"

  result = github_api(
    server_url: 'https://api.github.com',
    api_token: ENV['DANGER_GITHUB_API_TOKEN'],
    http_method: 'GET',
    path: "/repos/#{organisation}/#{repository}/pulls/#{options[:pr_id]}"
  )

  baseRef = result[:json]['base']['ref']

  # As CI fetches only the minimum we need to fetch the remote to make diffing work correctly.
  sh 'git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"'
  sh 'git fetch --no-recurse-submodules --no-tags'
  sh "git diff --name-only HEAD origin/#{baseRef}"
end

desc 'Check whether any of the changes happened in the given path'
desc ''
desc '#### Options'
desc ' * **`path`**: The path in which to check for changed files'
desc ''
lane :pr_changes_contains_path do |options|
  changes_contains_path = options[:changed_files].include?(options[:path])

  if changes_contains_path
    puts "Changes found for path #{options[:path]}"
  elsif puts "No changes found for path #{options[:path]}"
  end

  changes_contains_path
end

# This block will get executed when an error occurs, in any of the blocks (before_all, the lane itself or after_all).
error do |lane, exception|
  handle_error(lane, exception)
end
