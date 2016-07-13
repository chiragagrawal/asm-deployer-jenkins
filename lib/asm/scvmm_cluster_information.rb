#!/opt/puppet/bin/ruby

require 'trollop'
require 'json'
require 'winrm'

@opts = Trollop::options do
  opt :server, 'scvmm server address', :type => :string
  opt :username, 'scvmm server username', :type => :string
  opt :domain, 'scvmm server domain', :type => :string
  opt :password, 'scvmm server password', :type => :string
  opt :cluster, 'scvmm cluster name', :type => :string
end

def winrm
  endpoint = "http://#{@opts[:server]}:5985/wsman"
  WinRM::WinRMWebService.new(
    endpoint, :plaintext,
    :user => "#{@opts[:domain]}\\#{@opts[:username]}",
    :pass => @opts[:password],
    :disable_sspi => true
  )
end

result = winrm.powershell("Import-Module VirtualMachineManager;  Get-VMMServer -ComputerName localhost; Get-SCVMHostCluster | Where-Object -Property Name -Like #{@opts[:cluster]}.* ")
raise result[:data].collect{|l| l[:stderr]}.join if result[:exitcode] != 0
stdout = result[:data].collect{|l| l[:stdout]}.join
puts stdout 
exit 0
