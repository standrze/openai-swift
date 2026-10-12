require 'socket'
require 'openssl'
require 'json'
directory = ARGV.fetch(0)
context = OpenSSL::SSL::SSLContext.new
context.cert = OpenSSL::X509::Certificate.new(File.read(File.join(directory, 'server.crt')))
context.key = OpenSSL::PKey.read(File.read(File.join(directory, 'server.key')))
context.ca_file = File.join(directory, 'client.crt')
context.verify_mode = OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT
server = TCPServer.new('127.0.0.1', 0)
File.write(File.join(directory, 'port'), server.addr[1].to_s)
tls = OpenSSL::SSL::SSLServer.new(server, context)
loop do
  socket = nil
  begin
    socket = tls.accept
    while (line = socket.gets) && line != "\r\n"; end
    body = JSON.generate({ peer: socket.peer_cert.subject.to_s })
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  rescue OpenSSL::SSL::SSLError, IOError, SystemCallError
    # A failed client certificate handshake must not stop the next probe.
  ensure
    socket&.close
  end
end
