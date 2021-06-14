# coding: utf-8

require "socket"
require "cgi/util"
require "pathname"


LOG = Pathname(__dir__) / "bbs.log"

ss = TCPServer.open(8080)

class Part        #partクラスはpostリクエストを受け取り新規コメントを生成するためのクラス
  # @!attribute [r] type
  # @return [String] "text" or "file" Content-Disposition に filename が存在すると "file"、含まないと "text"
  attr_reader :type

  # @!attribute [r] name
  # @return [String] Content-Disposition で指定された name の値、例えば"commenter"、や"body_text"、"file"
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
      if line =~ /^Content-Disposition/         #nameの値やfilenameの値を抽出
        line.split(": ")[1].split("; ").each do |kv|
          k, v = kv.split("=")
          case k
          when "name"
            @name = v.gsub(/\"/, "")          #例えばcommenterが入る
          when "filename"
            filename = v.gsub(/\"/, "")       #例えばabc.txtが入る
            @type = "file"
            file = AttachedFile.new           #codeの引数なし、AttachedFileオブジェクトfileを生成
            file.original_name = filename
          else # k == "form-data"
            # do nothing
          end
        end
      elsif line =~ /^Content-Type/
        file.content_type = line[/Content-Type: (.*)$/, 1]
      elsif mode == "head" && line =~ /^$/     #空行を読み取ったらmodeをheadからbodyに切り替える
        mode = "body"
      elsif mode == "body"
        buf << line                            #bufには例えば「匿名希望」のようなデータの中身が入る 
      else
      end
    end
    buf.chomp!
    
    buf = buf.gsub(/(\r\n|\r|\n)/,"<br>") if type == "text"
    @value = type == "file" ? file.save(buf) : buf        #typeがfileなら、bufの内容をAttachedFileオブジェクトfileのcodeに対応するディレクトリに保存し、
                                                          #インスタンス変数valueにそのfileオブジェクトを入れる
                                                          #typeがfileではなくtextならbufの内容がそのままインスタンス変数valueに入る
    @value = "nanashi" if @name == "commenter" && buf == ""
  end
end

class AttachedFile
  # @!attribute [r] code
  # @return [String] AttacedFile の識別子 header ファイル data ファイルの保存先の ディレクトリ名としても使用、codeをたどって保存した画像のデータを参照できる
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
        File.open(header_file, mode ="r") do |f|        #codeディレクトリ内のheaderファイルを開く
          f.each_line do |line|
            line.chomp!
            if line =~ /^Content-Type: /
              @content_type = line.gsub("Content-Type: ", "")     #例えばimage/pngが入る
            elsif line =~ /^Original-Name: /
              @original_name = line.gsub("Original-Name: ", "")   #例えば画像名.PNGが入る
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

  # data ファイルとheader ファイルを格納する ディレクトリ@codeへの Path を返答
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
      Dir.mkdir(dir)                                      #@codeの名前のディレクトリを新規作成
      File.open(header_file, mode = "w") do |f|           #headerファイルを作成
        f.print("Content-Type: #{@content_type}\n")
        f.print("Original-Name: #{@original_name}\n")
      end
      File.binwrite(data_file, data)                      #dataファイルを作成

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


class PreparedFile
  # @!attribute [r] code
  # @return [String] AttacedFile の識別子 header ファイル data ファイルの保存先の ディレクトリ名としても使用、codeをたどって保存した画像のデータを参照できる
  attr_reader :img_name

  # @!attribute [rw] content_type
  # @return [String] 送信時に指定された Content-Type(MIME Type)
  attr_accessor :content_type

  # @!attribute [rw] original_name
  # @return [String] 送信された際のクライアント側のファイル名
  #attr_accessor :original_name

  # AttachedFileオブジェクトを作成
  # @param code [String] code が nil の場合は code を発生、nil の場合は 格納ディレクトリ の header ファイルを読み出し値をセット
  # @return [AttachedFile, nil] 生成した AttachedFile オブジェクト
  def initialize(img_name)
    @img_name = img_name
    @content_type = "image/png"
  end

  # data ファイルの Path を返答
  # @return [String] data ファイルの Path
  # @note data ファイルの内容は、アップロードされたファイルと同じ
  def data_file
    data_file = "#{Pathname(__dir__) / 'prepared_files' / @img_name}"
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
  attr_accessor :commenter                #attr_accessor:インスタンス変数を直接変更して操作ができるようにするもの

  # @!attribute [r] body_text
  # @return [String] 投稿したメッセージ
  attr_accessor :body_text

  # @!attribute [r] attached_file
  # @return [AttachedFile, nil] 投稿時に添付したファイル
  attr_accessor :attached_file

  # すべての Comment オブジェクトを Comment を記録した LOG ファイルから読み出し、配列形式で返答
  # @return [Array<Comment>] Comment オブジェクトの配列
  def self.read
    comments = []
    File.open(LOG, mode= "r") do |f|
      f.each_line do |line|
        line.chomp!
        datetime, commenter, body_text, attached_file_code = line.split("\t")
        attached_file = AttachedFile.new(attached_file_code) if attached_file_code    #attached_file_codeがあったらattached_fileオブジェクトを生成
        comments << Comment.new(commenter, body_text, attached_file, datetime)        #<<は配列末尾に挿入
      end                                                                             #新しく生成したCommentインスタンスを挿入
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
    @datetime = datetime ? datetime : "#{Time.new.strftime("%Y/%m/%d/%a/%T.%L")}"
  end

  # Comment オブジェクトを Comment を記録する LOG ファイルに書き込み
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
    [@datetime, @commenter, @body_text, attached_file_code].join("\t")      #logファイルに追記する内容
  end

  # Comment オブジェクトを HTML に変換する
  # @return [String] Comment オブジェクトを HTML に変換した文字列
  # @note ファイルが添付された場合と添付されていない場合で生成内容を切り替える
  def to_html
    html = "<span style=\"font-weight:bold; color:green;\">#{@commenter}さん </span>(#{@datetime})\n"
    if body_text != ""
      html << "<br>#{@body_text}"
    end
    if @attached_file
      if @attached_file.content_type =~ /^image/                #attached_fileのcontent_typeに"/^image/"が含まれていたら 
        html << "<br><img style=\"height: 200px; max-width: 100%;\" src=\"/download/#{@attached_file.code}\">\n"
      else
        html << "<br><a href=\"/download/#{@attached_file.code}\" target=\"_blank\">添付ファイル</a>\n"
      end
    end
    html << "<br><br>"
    html
  end
end

loop do
  Thread.start(ss.accept) do |s|
    next if (request_line = s.gets) == nil                #条件を満たすとき1ループ終わり
    # if (request_line = s.gets) == nil
    #   next
    # end
    method = request_line.split[0]
    pathname, params = request_line.split[1].split("?")

    if pathname == "/"
      header = {}
      while (line = s.gets.chomp) != ""                    #chompは文字列末尾の改行コードを削除
        key, value = line.split(": ")                      #httpリクエストの２行目以降を１行ずつリクエストヘッダー配列header配列に格納（連想配列）
        header[key] = value
      end

      case method
      when "GET"
        comments = Comment.read.reverse                                     #logファイルから読み込んだコメントオブジェクト群を逆順に並べ替えた配列、comments配列を生成
        message = comments.map {|comment| comment.to_html}.join("<br>")     #comments配列の各要素をhtmlに変換し<br>を間に入れて連結→messeage
        body = <<~EOHTML
          <html>
            <head>
              <link rel="icon" href="/favicon.ico" id="favicon">
            </head>
            <body>
              <p style="color:blue">こんにちは<img style=\"width: 30px; max-width: 100%;\" src=\"/prepared/ou.png\"></p>
              
              <form method="post" enctype="multipart/form-data">
                <label>name：<input type="text" name="commenter" value="匿名希望"></label><br>
                <label>comment：<textarea type="text" name="body_text" rows="4" cols="40" placeholder="コメントを記入してください"></textarea></label><br>
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
      when "POST"                                                         #httpリクエストがpostならリクエストヘッダー内に'Content-Type'がある
        if header['Content-Type'] =~ /^multipart\/form-data;/             #httpリクエストヘッダーの'Content-Type'が^multipart\/form-data;を含んでいたら 
          boundary = header['Content-Type'][/boundary=-*(.*$)/, 1]        #boundaryには----WebKitFormBoundaryYFDy799nrpTTLuBbのようなものが入る
          part = {}                                                       #連想配列p
          buf = ""
          while (line = s.gets) != nil                    #httpリクエストヘッダーの下にある情報を1行ずつ取得
            if line =~ /#{boundary}/                      ##{boundary}はboundaryに格納された文字列
              next if buf.size == 0                       #条件を満たすとき1ループ終わり
              p = Part.new(buf)                           #bufには各boundaryの間に書かれたものが貯めこまれる→partオブジェクト生成
              part[p.name] = p                            #各partオブジェクトを格納する連想配列p
              buf = ""
              break if line =~ /#{boundary}--/            #boundaryの最後まで行ったらwhileループをぬける
            else
              buf << line                                 
            end
          end
          comment = Comment.new(part['commenter'].value, part['body_text'].value, part['file'].value)   #part['body_text']やpart['file']はない場合がある
          comment.save if comment.body_text != "" || comment.attached_file != nil
        end
        status = "302 Found"
        header = "Location: /"
        body   = ""
      else
      end
    
    elsif pathname =~ /^\/download/             #クライアントが１回目のGETリクエストをしてサーバから返ってきたレスポンスに対してさらに画像などを要求するときのpath
                                                #例えば/download/LJSLWQWPがpathnameに入っている、これはto_htmlによるもの
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
    elsif pathname =~ /^\/prepared/
      img_name = pathname.gsub("/prepared/", "")
      file = PreparedFile.new(img_name)
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
