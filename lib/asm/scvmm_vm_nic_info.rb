#!/opt/puppet/bin/ruby

require 'trollop'
require 'json'
require 'winrm'

@opts = Trollop::options do
  opt :server, 'scvmm server address', :type => :string
  opt :username, 'scvmm server username', :type => :string
  opt :domain, 'scvmm server domain', :type => :string
  opt :password, 'scvmm server password', :type => :string
  opt :vmname, 'vmname', :type => :string
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

result = winrm.powershell("$Host.UI.RawUI.BufferSize = New-Object Management.Automation.Host.Size (500, 25); Import-Module VirtualMachineManager; $vmm = Get-VMMServer -ComputerName localhost; $refresh = Refresh-VM -VM #{@opts[:vmname]}; $vm_info = Get-VM -Name #{@opts[:vmname]} | Select -ExpandProperty Virtualnetworkadapters | ConvertTo-Json ; Write-Host $vm_info ")
stdout = result[:data].collect{|l| l[:stdout]}.join
puts stdout
exit 0
