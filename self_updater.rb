require 'webrick'
require 'erb'
require 'json'

def deployed_version
  `kubectl describe deploy sourcegraph-frontend | grep Image: | grep migrator: | cut -d: -f3`
    .strip
    .split("@")[0]
end

def frontend_status
  `kubectl get pod | grep sourcegraph-frontend | awk '{print $3}'`.strip.gsub("\n", " ")
end

$committed_update = false
$cooldown = false

def upgrade
  `kubectl apply --prune --all -f cluster.yaml`.strip
  $committed_update = true

  Thread.new {
    puts "Settling down"
    sleep(5)
    puts "Cooled down"
    $cooldown = true
  }
end

puts '
=========================================================
____ ____ _    ____    _  _ ___  ___  ____ ___ ____ ____ 
[__  |___ |    |___    |  | |__] |  \ |__|  |  |___ |__/ 
___] |___ |___ |       |__| |    |__/ |  |  |  |___ |  \ 

           ____ ____ ____ _  _ _ ____ ____ 
           [__  |___ |__/ |  | | |    |___ 
           ___] |___ |  \  \/  | |___ |___ 

=========================================================

'

puts "Current version: v#{deployed_version}"
puts

server = WEBrick::HTTPServer.new(
  Port: 8888, 
  Logger: WEBrick::Log.new("/dev/null"),
  AccessLog: [],
)

server.mount_proc '/upgrade' do |req, res|
  from = req.query['from'].gsub(/v/, "")
  to = req.query['to'].gsub(/v/, "")
  return_to = req.query['return_to']

  template = ERB.new(File.read('../self_updater.html.tmpl'))
  res.body = template.result(binding)

  puts "UPDATER: Got an upgrade request from v#{from} to v#{to} starting soon"

  Thread.new {
    sleep(5)
    puts "Starting update!"
    upgrade
  }
end

server.mount_proc '/complete' do |req, res|
  current = deployed_version
  fe_status = frontend_status
  to = req.query['to'].gsub(/v/, "")

  puts "-> Checking completion. Current version deployed: v#{current} (wants: v#{to})."

  msg = []

  if current == to
    msg << "Service is currently #{fe_status}."
    if fe_status == "Running" && $committed_update && $cooldown
      msg << "Update is complete!"
      res.body = JSON.generate({ status: 'ready' })  
    else
      msg << "Update is still going."
      res.body = JSON.generate({ status: 'working' })
    end
  else
    msg << "Waiting for upgrade to commence."
    res.body = JSON.generate({ status: 'working' })
  end

  puts "   " + msg.join(' ')
end

server.mount_proc '/favicon.ico' do |req, res|
  raise WEBrick::HTTPStatus::NotFound
end

trap 'INT' do server.shutdown end

server.start
