# coding: utf-8

require "socket"
require "cgi/util"
require "pathname"

LOG = Pathname(__dir__) / "bbs.log"

ss = TCPServer.open(8080)

class Part
  attr_accessor :type
  attr_accessor :name
  attr_accessor :value

  def initialize(type, name)
    @type = type
    @name = name
  end
end

class AttachedFile
  attr_accessor :code
  attr_accessor :content_type
  attr_accessor :original_name

  def self.load(code)
    file = self.new
    file.code = code

    File.open(file.header_file, mode ="r") do |f|
      f.each_line do |line|
        line.chomp!
        if line =~ /^Content-Type: /
          file.content_type = line.gsub("Content-Type: ", "")
        end
      end
    end
    file
  end

  def initialize(original_name = nil)
    if original_name
      @code = (0...8).map{ ('A'..'Z').to_a[rand(26)] }.join
      @original_name = original_name
    end
  end

  def dir
    Pathname(__dir__) / 'attached_files' / @code
  end

  def header_file
    data_file = "#{dir}/header"
  end

  def data_file
    data_file = "#{dir}/data"
  end

  def save(data)
    if data.size > 0
      Dir.mkdir(dir)
      File.binwrite(data_file, data)
      File.open(header_file, mode = "w") do |f|
        f.print("Content-Type: #{@content_type}\n")
        f.print("Original-Name: #{@original_name}\n")
      end

      self
    else
      nil
    end
  end

  def data
    File.binread(data_file)
  end
end

class Comment
  attr_accessor :commenter
  attr_accessor :body_text
  attr_accessor :attached_file

  def self.read
    comments = []
    File.open(LOG, mode= "r") do |f|
      f.each_line do |line|
        line.chomp!
        comments << Comment.new(line.split("\t"))
      end
    end
    comments
  end

  def save
    File.open(LOG, mode = "a") do |f|
      f.puts("#{self.serialize}")
    end
  end

  def initialize(args = nil)
    unless args
      @datetime = "#{Time.new}"
      @attached_file = nil
    else
      @datetime, @commenter, @body_text, attached_file_code = args
      if attached_file_code
        @attached_file = AttachedFile.load(attached_file_code)
      end
    end
  end

  def serialize
    if @attached_file
      attached_file = @attached_file.code
    end
    [@datetime, @commenter, @body_text, attached_file].join("\t")
  end

  def to_html
    html = "<b>#{@commenter}</b> : #{@body_text}(#{@datetime})\n"
    if @attached_file
      if @attached_file.content_type =~ /^image/
        html += "<br><img style=\"width: 100%\" src=\"/download/#{@attached_file.code}\">\n"
      else
        html += "<br><a href=\"/download/#{@attached_file.code}\" target=\"_blank\">添付ファイル</a>\n"
      end
    end
    html
  end
end

loop do
  Thread.start(ss.accept) do |s|
    next if (request_line = s.gets) == nil
    method = request_line.split[0]
    pathname, params = request_line.split[1].split("?")

    if pathname == "/"
      header = {}
      while (line = s.gets.chomp) != ""
        key, value = line.split(": ")
        header[key] = value
      end

      case method
      when "GET"
        comments = Comment.read
        message = comments.map {|comment| comment.to_html}.join("<br>")
        body = <<~EOHTML
          <html>
            <head>
              <link rel="icon" href="/favicon.ico" id="favicon">
            </head>
            <body>
              <p>こんにちは</p>
              <form method="post" enctype="multipart/form-data">
                <label>name：<input type="text" name="commenter" value="匿名希望"></label><br>
                <label>comment：<input type="text" name="body_text"></label><br>
                <label>file：<input type="file" name="file"></label><br>
                <input type="submit" value="send">
              </form>
              <hr>
              #{message}
            </body>
          </html>
        EOHTML

        status = "200 OK"
        header = "Content-Type: text/html; charset=utf-8"        
      when "POST"
        comment = Comment.new
        if header['Content-Type'] =~ /^multipart\/form-data;/
          boundary = header['Content-Type'][/boundary=-*(.*$)/, 1]
          part = nil
          mode = "head"
          file = nil
          buf  = ""
          while (line = s.gets) != nil
            line = line.chomp if mode == "head"
            if line =~ /#{boundary}/
              if part != nil
                case part.type
                when "text"
                  part.value = buf.chomp
                when "file"
                  part.value = file.save(buf.chomp)
                else
                end
                case part.name
                when "commenter"
                  comment.commenter = part.value
                when "body_text"
                  comment.body_text = part.value
                when "file"
                  comment.attached_file = part.value
                else
                end
              end
              break if line =~ /#{boundary}--/
              mode = "head"
              part = nil
              buf  = ""
            elsif line =~ /^Content-Disposition/
              type = "text"
              name = nil
              key_values = line.split(": ")[1].split("; ").each do |kv|
                k, v = kv.split("=")
                case k
                when "name"
                  name = v.gsub(/\"/, "")
                when "filename"
                  filename = v.gsub(/\"/, "")
                  type = "file"
                  file = AttachedFile.new(filename)
                else # k == "form-data"
                  # do nothing
                end
              end
              part = Part.new(type, name)
            elsif line =~ /^Content-Type/
              file.content_type = line[/Content-Type: (.*)$/, 1]
            elsif mode == "head" && line =~ /^$/
              mode = "body"
            elsif mode == "body"
              buf += line
            else
            end
          end
          comment.save
        end
        status = "302 Found"
        header = "Location: /"
        body   = ""
      else
      end
    
    elsif pathname =~ /^\/download/
      code = pathname.gsub("/download/", "")
      file = AttachedFile.load(code)
      if file
        status = "200 OK"
        header = "Content-Type: #{file.content_type}"
        body   = file.data
      else
        status = "404 Not found"
        header = ""
        body   = ""
      end
    else
      status = "404 Not found"
      header = ""
      body   = ""
    end

    s.write(<<~EOHTTP)
      HTTP/1.0 #{status}
      #{header}

      #{body}
    EOHTTP

    s.close
  end
end
