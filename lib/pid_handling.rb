module PidHandling
  
  def pids
    @@pids ||= {}
  end
  
  def pid_exists?(pid)
    pids.key?(pid)
  end
  
  def add_pid(pid, remote_ip)
    return if pid_exists?(pid)  
    pids[pid] = remote_ip
  end
  
  def remove_pid(pid)
    pids.delete(pid)
  end
  
  def find_by_connection(connection)
    pids.each_pair do |pid,key|
      if key == connection
        return pid
      end
    end
    nil
  end
   
  def kill_existing_process(key)
    if pid = Handler.find_by_connection(key)
      puts "== Terminating existing process #{pid}"
      Process.kill('TERM', pid)
    end
  end
  
end