require 'httpclient'
require 'net/http'
require 'yaml'
require 'timeout'

def buildwise_start_build(options)
  the_response_content = contact_buildwise_post("/builds/begin", "options" => YAML.dump(options))
  # puts "DEBUG: " + YAML.dump(options)
  new_build_id = the_response_content
end

def buildwise_finish_build(build_id)
  puts "[buildwise.rake] Finishing build: #{build_id}"
  if build_id && (build_id.class == Integer  || build_id =~ /\d+/)
    pdata = {
      "id" =>  build_id,
    }         
    outcome = contact_buildwise_post("/builds/#{build_id}/finish", pdata)    
    puts "[buildwise.rake] Post /builds/#{build_id}/finish => #{outcome}"
    return outcome
  end
end

def buildwise_build_status(build_id)
  begin
    return contact_buildwise_get("/builds/#{build_id}/status")
  rescue => e
    return "Pending"
  end
end

def buildwise_build_ui_test_status(build_id)
  begin
    the_status = contact_buildwise_get("/builds/#{build_id}/ui_test_status")
    the_status = the_status[0..20].strip rescue "" # avoid long html error in case server error
  rescue => e
    the_status = "Pending"
  end
  return the_status
end

def buildwise_build_failed(build_id)
  failed_files = contact_buildwise("/builds/#{build_id}/failures?stage=Functional") if build_id && build_id =~ /\d+/
  failed_file_list = failed_files.split(",")
end

# TODO when the Rake task is loaded, it will be invoked straight way
# 
# Check the builder order for this project
#
# @params: project_identifier, a string unique identifier
def buildwise_ui_test_order(project_identifier)
  puts "[INFO] Check test order of project identifier: #{project_identifier}"
  
  if project_identifier
    ui_test_in_order = contact_buildwise_get("/projects/#{project_identifier}/ui_test_priority", false)
    # puts "Get test order: #{ui_test_in_order}"
    ui_test_in_order.split(",")  rescue nil
  else
    return nil
  end
end


def buildwise_failed_build_tests(project_identifier)
  if project_identifier
    failed_full_build_tests = contact_buildwise_get("/projects/#{project_identifier}/failed_tests")
    failed_full_build_tests.split(",")  rescue []
  else
    return []
  end
end

def buildwise_successful_build_tests(project_identifier)
  if project_identifier
    failed_full_build_tests = contact_buildwise_get("/projects/#{project_identifier}/successful_tests")
    failed_full_build_tests.split(",")  rescue []
  else
    return []
  end
end


## Invoke a build task to run test sequentially, when it finished, inform BuildWise
# :max_wait_time => 3600, :check_interval => 20,
#
def buildwise_run_sequential_build_target(build_id, task_name)  
  begin
    FileUtils.rm_rf("spec/reports") if File.exists?("spec/reports")
    Rake::Task[task_name].invoke
  ensure
    puts "Finished: Notify build status"
    sleep 2 # wait a couple of seconds to finish writing last test results xml file out
    puts "[Rake] finish the build"
    buildwise_finish_build(build_id)
  end
end


#
# :max_wait_time => 3600, :check_interval => 20,
#
def buildwise_montior_parallel_execution(build_id, opts = {})  
  start_time = Time.now 
  
  default_opts = {:max_wait_time => 3600, :check_interval => 15}
  # default to checking ervery 10 seconds for one hour, unless specified
  the_opts = default_opts.merge(opts)
  
  max_wait_time = the_opts[:max_wait_time]
  check_interval = the_opts[:check_interval]
  
  max_wait_time = 1800 if max_wait_time < 60
  check_interval = 15 if check_interval < 5
  
  puts "[buildwise.rake] Keep checking build |#{build_id} for max #{max_wait_time} for every #{check_interval} seconds"
  
  fio = nil
  if ENV["ARTIFACT_DIR"] && Dir.exists?(ENV["ARTIFACT_DIR"])
    tmp_log_file = File.join(ENV["ARTIFACT_DIR"], "rake_parallel.log")    
    FileUtils.rm(tmp_log_file) if File.exists?(tmp_log_file)
    puts("[buildwise.rake] logging parallel monitoring to #{tmp_log_file}")
    fio = File.open(tmp_log_file, "a")    
    fio.puts("[#{Time.now}]  Keep checking build |#{build_id}| for max #{max_wait_time} for every #{check_interval} seconds")
  end
  
  begin 
    Timeout::timeout(max_wait_time + 120) { 
  
      $last_buildwise_server_build_status = nil
      while ((Time.now - start_time ) < max_wait_time) # test exeuction timeout
        the_build_status = buildwise_build_ui_test_status(build_id) rescue "Pending"
        if fio
          fio.puts("[#{Time.now}] build status => |#{the_build_status}|")
          fio.flush
        end
    
        if ($last_buildwise_server_build_status != the_build_status)
          puts "[Rake] #{Time.now} Checking build status: |#{the_build_status}|"
          $last_buildwise_server_build_status = the_build_status
        end
    
        if the_build_status == "OK"
          fio.close
          exit 0
        elsif the_build_status == "Failed"
          fio.close
          exit -1
        else 
          if (the_build_status != "Pending")
            puts("[Rake] functional testing status => #{the_build_status},  next check in #{FULL_BUILD_CHECK_INTERVAL} seconds")
          end
          sleep FULL_BUILD_CHECK_INTERVAL  # check the build status every minute
        end
      end
  
    }
  rescue Timeout::Error => e
    if fio
      fio.puts("[#{Time.now}] execution timeouts!")
      fio.close
    end    
    puts("[Rake] execution time outs!")
    exit -3  
  end
    
  puts "[Rake] Execution UI tests expired"
  if fio
    fio.puts("[#{Time.now}] ends normally")
    fio.close
  end
  exit -2
end

def contact_buildwise_get(path, raise_exception = false)
  if path.nil? || path.size() > 256
    raise "Invalid path"
  end
  
  begin
    client = HTTPClient.new
    url = "#{BUILDWISE_URL}#{path}"
    # puts "[buildwise.rake] Contacting Server: #{url}"
    the_res = client.get(url).body
    the_res = the_res.content if the_res.respond_to?("content")
    return nil if the_res.include?("Internal Server Error")
    return the_res
  rescue => e
    puts "error to contact BAM with GET:  #{e}"
    if raise_exception 
      raise e
    else
      return nil
    end
  end
end

def contact_buildwise_post(path, pdata)
  begin
    url = "#{BUILDWISE_URL}#{path}"
    puts "[buildwise.rake] Posting to |#{url}|"
    response = HTTPClient.new.post(url, pdata)
    the_res = response.body
    the_res = the_res.content if the_res.respond_to?("content")    
    return the_res
  rescue => e
    puts "error to contact BuildWise Server #{BUILDWISE_URL} with POST:  #{e}"
    return nil
  end  
end


## 
# A convenient method to get a list spec in a preferred order, supports the following mode
# if the corresponding environment variables are set. 
# 
#  INTELLIGENT_ORDERING: get recent-failed-come-first older from BuildWise execution history
#  DYNAMIC_FEEDBACK: add failed tests from another Build project (parallel)
#
# @spec_file_list: an arary containing a list of spec to be in the build
# @excluded: an array containing specs exluced from the build
# @spec_dir: if provided, 
#      
def buildwise_determine_specs_for_quick_build(spec_file_list, excluded = [], spec_dir=nil)
  specs_to_be_executed = []

  enable_intelligent_ordering = ENV["INTELLIGENT_ORDERING"] && ENV["INTELLIGENT_ORDERING"].to_s == "true"
  puts "[INFO] intelligent ordering? => #{enable_intelligent_ordering.to_s rescue 'false'}"

  if enable_intelligent_ordering && ENV["BUILDWISE_PROJECT_IDENTIFIER"]
    ordered_specs = buildwise_ui_test_order(ENV["BUILDWISE_PROJECT_IDENTIFIER"])
    puts "[INFO] Execution order based history of quick build: #{ordered_specs.inspect}"
    if ordered_specs.nil? || ordered_specs.compact.empty? || ordered_specs.class != Array
      specs_to_be_executed += spec_file_list  if specs_to_be_executed.empty?
    else
      # neat sorting thanks to Ruby
      specs_to_be_executed = ordered_specs.dup
      specs_to_be_executed = specs_to_be_executed.sort_by{|x| ordered_specs.include?(File.basename(x)) ? ordered_specs.index(File.basename(x)) : specs_to_be_executed.count }    
      puts "[INFO] After intelligent sorting => #{specs_to_be_executed.inspect}"        
    end    
  end

  enable_dynamic_build_queue = ENV["DYNAMIC_FEEDBACK"] && ENV["DYNAMIC_FEEDBACK"].to_s == "true" && ENV["DYNAMIC_FEEDBACK_PROJECT_IDENTIFIER"]
  puts "[INFO] dynamic feedback? => #{enable_dynamic_build_queue}"  
  if enable_dynamic_build_queue
    begin
      # dynamic build process: get failed tests from last failed full build
      failed_full_build_tests = buildwise_failed_build_tests(ENV["DYNAMIC_FEEDBACK_PROJECT_IDENTIFIER"])
      if failed_full_build_tests && failed_full_build_tests.size > 0
        failed_full_build_tests.each do |x|
          full_path = File.join($spec_dir, x)
          specs_to_be_executed.insert(0, full_path) unless specs_to_be_executed.include?(full_path)
        end    
      end      
    rescue => e
      puts "[ERROR] failed to check for full build: #{e}"
    end
  end

  if specs_to_be_executed.empty?
    specs_to_be_executed = spec_file_list   
  else
    specs_left_over = spec_file_list - specs_to_be_executed
    specs_to_be_executed += specs_left_over
    specs_to_be_executed.flatten!
  end
  specs_to_be_executed -= excluded
  specs_to_be_executed.uniq!
  puts "[INFO] Uniq : #{specs_to_be_executed.inspect}"

  
  if spec_dir
    specs_to_be_executed.reject! {|a_test|  !File.exists?(File.join(spec_dir, a_test)) }
  else
    specs_to_be_executed.reject! {|a_test|  !File.exists?(a_test) }  
  end
  puts "[INFO] Filter Not exists : #{specs_to_be_executed.inspect}"


  puts "[INFO] Final Test execution in order => #{specs_to_be_executed.inspect}"
  if spec_dir
    specs_to_be_executed = specs_to_be_executed.collect{|x| File.expand_path( File.join(spec_dir, x) ) }  
  else
    specs_to_be_executed = specs_to_be_executed.collect{|x| File.expand_path(x) }  
  end
end

