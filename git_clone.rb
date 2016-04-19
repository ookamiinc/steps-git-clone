require 'base64'
require 'fileutils'
require 'uri'
require 'optparse'

options = {
	user_home: ENV['HOME'],
	private_key_file_path: nil,
	formatted_output_file_path: nil,
}

opt_parser = OptionParser.new do |opt|
	opt.banner = "Usage: git_clone.rb [OPTIONS]"
	opt.separator ""
	opt.separator "Options (options without [] are required)"

	opt.on("--repo-url URL", "repository url") do |value|
		options[:repo_url] = value
	end

	opt.on("--branch [BRANCH]", "branch name. IMPORTANT: if tag is specified the branch parameter will be ignored!") do |value|
		options[:branch] = value
	end

	opt.on("--tag [TAG]", "tag name. IMPORTANT: if tag is specified the branch parameter will be ignored!") do |value|
		options[:tag] = value
	end

	opt.on("--commit-hash [COMMITHASH]", "commit hash. IMPORTANT: if commit-hash is specified the branch and tag parameters will be ignored!") do |value|
		options[:commit_hash] = value
	end

	opt.on("--pull-request [PULL-REQUEST-ID]", "pull request id. IMPORTANT: works only with GitHub") do |value|
		options[:pull_request_id] = value
	end

	opt.on("--dest-dir [DESTINATIONDIR]", "local clone destination directory path") do |value|
		options[:clone_destination_dir] = value
	end

	opt.on("--clone-depth [CLONE-DEPTH]", "limit fetching to the specified number of commits") do |value|
		options[:clone_depth] = value
	end

	opt.on("--formatted-output-file [FILE-PATH]", "If given a formatted (markdown) output will be generated") do |value|
		options[:formatted_output_file_path] = value
	end

	opt.on("-h","--help","Shows this help message") do
		puts opt_parser
	end
end

ssh_key_from_env = ENV['auth_ssh_private_key']
if ssh_key_from_env
	options[:auth_ssh_key_raw] = ssh_key_from_env
end

opt_parser.parse!

if options[:formatted_output_file_path] and options[:formatted_output_file_path].length < 1
	options[:formatted_output_file_path] = nil
end


#
# Print configs
puts
puts '========== Configs =========='
puts " * repo_url: #{options[:repo_url]}"
puts " * branch: #{options[:branch]}"
puts " * tag: #{options[:tag]}"
puts " * commit_hash: #{options[:commit_hash]}"
puts " * pull_request_id: #{options[:pull_request_id]}"
puts " * clone_destination_dir: #{options[:clone_destination_dir]}"
puts " * clone_depth: #{options[:clone_depth]}"
puts " * formatted_output_file_path: #{options[:formatted_output_file_path]}"
puts " * auth_ssh_key_raw: #{options[:auth_ssh_key_raw].to_s.empty? ? 'no SSH key provided' : '*****'}"
puts

unless options[:repo_url] and options[:repo_url].length > 0
	puts opt_parser
	exit 1
end



# -----------------------
# --- functions
# -----------------------


def write_private_key_to_file(user_home, auth_ssh_private_key)
	private_key_file_path = File.join(user_home, '.ssh/bitrise')

	# create the folder if not yet created
	FileUtils::mkdir_p(File.dirname(private_key_file_path))

	# private key - save to file
	File.open(private_key_file_path, 'wt') { |f| f.write(auth_ssh_private_key) }
	system "chmod 600 #{private_key_file_path}"

	return private_key_file_path
end


# -----------------------
# --- main
# -----------------------

# normalize input pathes
options[:clone_destination_dir] = File.expand_path(options[:clone_destination_dir])
puts " (i) expanded/absolute clone_destination_dir: #{options[:clone_destination_dir]}"

if options[:formatted_output_file_path]
	options[:formatted_output_file_path] = File.expand_path(options[:formatted_output_file_path])
end


#
prepared_repository_url = options[:repo_url]

if !options[:auth_ssh_key_raw].to_s.empty?
	options[:private_key_file_path] = write_private_key_to_file(options[:user_home], options[:auth_ssh_key_raw])
else
	# Auth: No Authentication information found - trying without authentication
end

# do clone
git_checkout_parameter = nil
# git_branch_parameter = ""
if options[:pull_request_id] and options[:pull_request_id].length > 0
	git_checkout_parameter = "pull/#{options[:pull_request_id]}"
elsif options[:commit_hash] and options[:commit_hash].length > 0
	git_checkout_parameter = options[:commit_hash]
elsif options[:tag] and options[:tag].length > 0
	# since git 1.8.x tags can be specified as "branch" too ( http://git-scm.com/docs/git-clone )
	#  [!] this will create a detached head, won't switch to a branch!
	# git_branch_parameter = "--single-branch --branch #{options[:tag]}"
	git_checkout_parameter = options[:tag]
elsif options[:branch] and options[:branch].length > 0
	# git_branch_parameter = "--single-branch --branch #{options[:branch]}"
	git_checkout_parameter = options[:branch]
else
	# git_branch_parameter = "--no-single-branch"
	puts " [!] No checkout parameter found"
end



$options = options
$prepared_repository_url = prepared_repository_url
$git_checkout_parameter = git_checkout_parameter
$this_script_path = File.expand_path(File.dirname(__FILE__))

class String
	def prepend_lines_with(prepend_with_string)
		return self.gsub(/^.*$/, prepend_with_string.to_s+'\&')
	end
end

def write_string_to_formatted_output(str_to_write)
	formatted_output_file_path = $options[:formatted_output_file_path]
	if formatted_output_file_path
		File.open(formatted_output_file_path, "w+") { |f|
			f.puts(str_to_write)
		}
	end
end

def export_step_output(key, value)
	IO.popen("envman add --key #{key}", 'r+') {|f|
		f.write(value)
		f.close_write
		f.read
	}
end

def do_clone()
	git_check_path = File.join($options[:clone_destination_dir], '.git')
	if Dir.exist?(git_check_path)
		puts " [!] .git folder already exists in the destination dir at : #{git_check_path}"
		return false
	end
	unless system(%Q{mkdir -p "#{$options[:clone_destination_dir]}"})
		puts " [!] Failed to create the clone_destination_dir at : #{$options[:clone_destination_dir]}"
		return false
	end

	is_clone_success = false
	commit_hash_str = ''

	Dir.chdir($options[:clone_destination_dir]) do
		begin
			unless system(%Q{git init})
				raise 'Could not init git repository'
			end

			ssh_no_prompt_file = 'ssh_no_prompt.sh'
			if $options[:private_key_file_path]
				ssh_no_prompt_file = 'ssh_no_prompt_with_id.sh'
			end

			unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/#{ssh_no_prompt_file}" git remote add origin "#{$prepared_repository_url}"})
				raise 'Could not add remote'
			end

			fetch_command = "git fetch"
			if $options[:pull_request_id] and $options[:pull_request_id].length > 0
				fetch_command += " origin pull/#{$options[:pull_request_id]}/merge:#{$git_checkout_parameter}"
			elsif $options[:tag] and $options[:tag].length > 0
				fetch_command += " origin #{$options[:tag]}"
			elsif $options[:branch] and $options[:branch].length > 0
				fetch_command += " origin #{$options[:branch]}"
			end
			if $options[:clone_depth] and $options[:clone_depth].length > 0
				fetch_command += " --depth=#{$options[:clone_depth]}"
			end
			unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/ssh_no_prompt.sh" #{fetch_command}})
				raise 'Could not fetch from repository'
			end

			if $git_checkout_parameter != nil
				unless system("git checkout #{$git_checkout_parameter}")
					raise "Could not do checkout #{$git_checkout_parameter}"
				end

				unless system(%Q{GIT_ASKPASS=echo GIT_SSH="#{$this_script_path}/ssh_no_prompt.sh" git submodule update --init --recursive})
					raise 'Could not fetch from submodule repositories!'
				end

				# git clone stats
				commit_hash_str = `git log -1 --format="%H"`.chomp
				commit_msg_subject_str = `git log -1 --format="%s"`.chomp
				commit_msg_body_str = `git log -1 --format="%b"`.chomp
				commit_author_name_str = `git log -1 --format="%an"`.chomp
				commit_author_email_str = `git log -1 --format="%ae"`.chomp
				commit_commiter_name_str = `git log -1 --format="%cn"`.chomp
				commit_commiter_email_str = `git log -1 --format="%ce"`.chomp


				export_step_output('GIT_CLONE_COMMIT_HASH', commit_hash_str)
				export_step_output('GIT_CLONE_COMMIT_MESSAGE_SUBJECT', commit_msg_subject_str)
				export_step_output('GIT_CLONE_COMMIT_MESSAGE_BODY', commit_msg_body_str)
				export_step_output('GIT_CLONE_COMMIT_AUTHOR_NAME', commit_author_name_str)
				export_step_output('GIT_CLONE_COMMIT_AUTHOR_EMAIL', commit_author_email_str)
				export_step_output('GIT_CLONE_COMMIT_COMMITER_NAME', commit_commiter_name_str)
				export_step_output('GIT_CLONE_COMMIT_COMMITER_EMAIL', commit_commiter_email_str)



				formatted_output_file_path = $options[:formatted_output_file_path]
				if formatted_output_file_path
					commit_log_str = `git log -n 1 --tags --branches --remotes --format="fuller"`
					commit_log_str = commit_log_str.prepend_lines_with('    ')
					write_string_to_formatted_output(%Q{
# Commit Hash

	#{commit_hash_str}

# Commit Log

	#{commit_log_str}
})
				end
			else
				puts " (!) No checkout parameter (branch, tag, commit hash or pull-request ID) provided!"
			end

			is_clone_success = true
		rescue => ex
			puts "Error: #{ex}"
		end
	end

	unless is_clone_success
		# delete it
		system(%Q{rm -rf "#{$options[:clone_destination_dir]}"})
	end

	return is_clone_success, commit_hash_str
end

is_clone_success, commit_hash = do_clone()
puts "Clone Is Success?: #{is_clone_success}"
puts "Cloned commit hash: #{commit_hash}"

if options[:private_key_file_path]
	puts " (i) Removing private key file: #{options[:private_key_file_path]}"
	system(%Q{rm -P #{options[:private_key_file_path]}})
end

exit (is_clone_success ? 0 : 1)
