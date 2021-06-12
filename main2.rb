# coding: utf-8

require "socket"
require "cgi/util"
require "pathname"

LOG = Pathname(__dir__) / "bbs.log"

ss = TCPServer.open(8080)

class Part
  # @!attribute [r] type
  # @return [String] "text" or "file" Content-Disposition に filename を含むと "file"、含まないと "text"
  attr_reader :type

  # @!attribute [r] name
  # @return [String] Content-Disposition で指定された name の値
  attr_reader :name

  # @!attribute [r] value
  # @return [String, AttachedFile, nil] type が "file" の場合は AttachedFile オブジェクト "text"　の場合は String
  #   空行で区切られた下部の値にそれぞれのオブジェクトを生成し、セットする
  attr_reader :value

  # multipart/form-data の個々の Part を作成
  # @param data [String] boundary で囲まれた内側の raw data
  # @return [Part] 生成した Part オブジェクト
  # @note raw data を parse しながらオブジェクトを生成
  # @see multipart/form-data
  # ------WebKitFormBoundaryKMGVZ5HAdk5QovBV
  # Content-Disposition: form-data; name="commenter"
  # 
  # 匿名希望
  # ------WebKitFormBoundaryKMGVZ5HAdk5QovBV
  # Content-Disposition: form-data; name="body_text"
  # 
  # さしすせそ
  # ------WebKitFormBoundaryKMGVZ5HAdk5QovBV
  # Content-Disposition: form-data; name="file"; filename="abc.txt"
  # Content-Type: text/plain
  # 
  # AAA
  # BBB
  # CCC
  # ------WebKitFormBoundaryKMGVZ5HAdk5QovBV--
  def initialize(data)
    @type = "text"
    mode = "head"
    buf = ""
    file = nil
    data.each_line do |line|
      line.chomp! if mode == "head"
      if line =~ /^Content-Disposition/
        line.split(": ")[1].split("; ").each do |kv|
          k, v = kv.split("=")
          case k
          when "name"
            @name = v.gsub(/\"/, "")
          when "filename"
            filename = v.gsub(/\"/, "")
            @type = "file"
            file = AttachedFile.new
            file.original_name = filename
          else # k == "form-data"
            # do nothing
          end
        end
      elsif line =~ /^Content-Type/
        file.content_type = line[/Content-Type: (.*)$/, 1]
      elsif mode == "head" && line =~ /^$/
        mode = "body"
      elsif mode == "body"
        buf << line
      else
      end
    end
    buf.chomp!
    @value = type == "file" ? file.save(buf) : buf
  end
end

class AttachedFile
  # @!attribute [r] code
  # @return [String] AttacedFile の識別子 header ファイル data ファイルの保存先の ディレクトリ名としても使用
  attr_reader :code

  # @!attribute [rw] content_type
  # @return [String] 送信時に指定された Content-Type(MIME Type)
  attr_accessor :content_type

  # @!attribute [rw] original_name
  # @return [String] 送信された際のクライアント側のファイル名
  attr_accessor :original_name

  # AttachedFileオブジェクトを作成
  # @param code [String] code が nil の場合は code を発生、nil の場合は 格納ディレクトリ の header ファイルを読み出し値をセット
  # @return [AttachedFile, nil] 生成した AttachedFile オブジェクト
  def initialize(code = nil)
    if code
      @code = code
      if @code.size > 0 && Dir.exist?(dir)
        File.open(header_file, mode ="r") do |f|
          f.each_line do |line|
            line.chomp!
            if line =~ /^Content-Type: /
              @content_type = line.gsub("Content-Type: ", "")
            elsif line =~ /^Original-Name: /
              @original_name = line.gsub("Original-Name: ", "")
            else
            end
          end
        end
      else
        nil
      end
    else
      @code = (0...8).map{ ('A'..'Z').to_a[rand(26)] }.join
    end
  end

  # data ファイル、header ファイルを格納する ディレクトリ Path を返答
  # @return [String] ディレクトリ Path
  def dir
    Pathname(__dir__) / 'attached_files' / @code
  end

  # header ファイルの Path を返答
  # @return [String] header ファイルの Path
  # @note header ファイルの内容は、Contet-Type と Original-Name を格納
  def header_file
    data_file = "#{dir}/header"
  end

  # data ファイルの Path を返答
  # @return [String] data ファイルの Path
  # @note data ファイルの内容は、アップロードされたファイルと同じ
  def data_file
    data_file = "#{dir}/data"
  end

  # 添付ファイルオブジェクトを永続化(アップロードされたファイルをサーバ側に保存)
  # @param data [String] data ファイルに保存される内容
  # @return [AttachedFile, nil] 自分自身のオブジェクトを返答　ただし、引数で渡された data が 0 バイトの場合 nil を返答
  # @note data ファイルの内容が、文字列データかバイナリデータかには関与せず、一律バイナリデータとして処理
  def save(data)
    if data.size > 0
      Dir.mkdir(dir)
      File.open(header_file, mode = "w") do |f|
        f.print("Content-Type: #{@content_type}\n")
        f.print("Original-Name: #{@original_name}\n")
      end
      File.binwrite(data_file, data)

      self
    else
      nil
    end
  end

  # 添付ファイルのデータを返答
  # @return [String] data ファイルを読み出し、返答
  def data
    File.binread(data_file)
  end
end

class Comment
  # @!attribute [r] commenter
  # @return [String] 投稿者の名前
  attr_accessor :commenter

  # @!attribute [r] body_text
  # @return [String] 投稿したメッセージ
  attr_accessor :body_text

  # @!attribute [r] attached_file
  # @return [AttachedFile, nil] 投稿時に添付したファイル
  attr_accessor :attached_file

  # すべての Comment オブジェクトを Comment を記録した LOG ファイから読み出し、配列形式で返答
  # @return [Array<Comment>] Comment オブジェクトの配列
  def self.read
    comments = []
    File.open(LOG, mode= "r") do |f|
      f.each_line do |line|
        line.chomp!
        datetime, commenter, body_text, attached_file_code = line.split("\t")
        attached_file = AttachedFile.new(attached_file_code)
        comments << Comment.new(commenter, body_text, attached_file, datetime)
      end
    end
    comments
  end

  # Comment オブジェクトを生成する
  # @param commenter [String] 投稿者の名前
  # @param body_text [String] 投稿したメッセージ
  # @param attached_file [Attached_file] 投稿時に添付したファイル
  # @param datetime [String] 投稿日を表す文字列
  # @return [Comment] Comment オブジェクト
  # @note datetime が nil の場合(新規投稿時)は、当該メソッドを呼び出したした日付(現在の日付)をセットする
  def initialize(commenter, body_text, attached_file, datetime = nil)
    @commenter = commenter
    @body_text = body_text
    @attached_file = attached_file
    @datetime = datetime ? datetime : "#{Time.new}"
  end

  # Comment オブジェクトを Comment を記録する LOG ファイに書き込み
  # @return [Array<Comment>] Comment オブジェクトの配列
  def save
    File.open(LOG, mode = "a") do |f|
      f.puts("#{self.serialize}")
    end
  end

  # Comment オブジェクトをファイルに保存するために一つのまとまった文字列に変換する
  # @return [String] Comment オブジェクトのインスタンス変数の値をタブで結合した文字列
  # @note datetime, commenter, body_text, Attached オブジェクトの code の順に結合、各インスタンス変数にはタブが含まれない想定
  def serialize
    attached_file_code = @attached_file ? @attached_file.code : ""
    [@datetime, @commenter, @body_text, attached_file_code].join("\t")
  end

  # Comment オブジェクトを HTML に変換する
  # @return [String] Comment オブジェクトを HTML に変換した文字列
  # @note ファイルが添付された場合と添付されていない場合で生成内容を切り替える
  def to_html
    html = "<b>#{@commenter}</b> : #{@body_text}(#{@datetime})\n"
    if @attached_file
      if @attached_file.content_type =~ /^image/
        html << "<br><img style=\"width: 600px; max-width: 100%;\" src=\"/download/#{@attached_file.code}\">\n"
      else
        html << "<br><a href=\"/download/#{@attached_file.code}\" target=\"_blank\">添付ファイル</a>\n"
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
        if header['Content-Type'] =~ /^multipart\/form-data;/
          boundary = header['Content-Type'][/boundary=-*(.*$)/, 1]
          part = {}
          buf = ""
          while (line = s.gets) != nil
            if line =~ /#{boundary}/
              next if buf.size == 0
              p = Part.new(buf)
              part[p.name] = p
              buf = ""
              break if line =~ /#{boundary}--/
            else
              buf << line
            end
          end
          comment = Comment.new(part['commenter'].value, part['body_text'].value, part['file'].value)
          comment.save
        end
        status = "302 Found"
        header = "Location: /"
        body   = ""
      else
      end
    
    elsif pathname =~ /^\/download/
      code = pathname.gsub("/download/", "")
      file = AttachedFile.new(code)
      if file
        status = "200 OK"
        header = "Content-Type: #{file.content_type}"
        body   = file.data
      else
        status = "404 Not found"
        header = ""
        body   = "Request-URI Not Found"
      end
    else
      status = "404 Not found"
      header = ""
      body   = "Request-URI Not Found"
    end

    s.write(<<~EOHTTP)
      HTTP/1.0 #{status}
      #{header}

      #{body}
    EOHTTP

    s.close
  end
end
