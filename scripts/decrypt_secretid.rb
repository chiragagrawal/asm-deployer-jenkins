#!/opt/puppet/bin/ruby

$: << "/opt/asm-deployer/lib"

require 'asm'
require 'asm/cipher'

cred = ARGV.first || abort("Please specify an encrypted string as first argument")

begin
  puts ASM::Cipher.decrypt_string(cred)
rescue
  abort("Could not decrypt the string: %s" % $!.to_s)
end
