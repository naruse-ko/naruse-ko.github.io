# coding: utf-8

require "socket"
require "cgi/util"
require "pathname"

LOG = Pathname(__dir__) / "bbs.log"

ss = TCPServer.open(8080)

loop do
  Thread.start(ss.accept) do |s|
    path, params = s.gets.split[1].split("?")

    header = ""
    body = ""
    myname = "名無し"
    value = ""

	if params != nil
      params.split("&").each do |param|
        pair = param.split("=")
        pname = pair[0]
        pvalue = CGI.unescape(pair[1]==nil ? "" : pair[1])
        myname = pvalue if pname == "myname"
        value = pvalue if pname == "value"
      end
	end

    if path == "/"
      status = "200 OK"
      header = "Content-Type: text/html; charset=utf-8"

      log = []

      if value != ""
        log.unshift("<b>#{myname}</b> : #{value} (#{Time.new})<br>\n")

        File.open(LOG, "a") do |f|
          f.print log.join("\n") 
        end
      end

      message = File.read(LOG)

      body = <<~EOHTML
        <html>
          <body>
            <p>こんにちは</p>
            <form method="get">
              <label>name：<input type="text" name="myname" value="名無し"></label><br>
              <label>comment：<input type="text" name="value"></label>
              <input type="submit" value="send">
            </form>
            <hr>
            #{message}
            #{body}
          </body>
        </html>
      EOHTML
    else
      status = "302 Moved"
      header = "Location: /"
    end

    s.write(<<~EOHTTP)
      HTTP/1.0 #{status}
      #{header}

      #{body}
    EOHTTP

    puts "#{Time.new} #{status} #{path}"

    s.close
  end
end
