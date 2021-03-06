require 'rexml/document'

$: << ENV['TM_SUPPORT_PATH'] + '/lib'
require "textmate"

class RtfExporter
  
  def initialize
    @styles={}  
    @colors = ""
    @num_colors=1
  end
  
  def generate_rtf input
    generate_stylesheet_from_theme
    doc = rtf_document input
    CGI.unescapeHTML(doc)
  end
  
  def add_style_recursive scopes, style, styles
    current = scopes.shift.strip
    styles[current] ||= {}
    if scopes.empty?
      styles[current][:default] = style
    else
      add_style_recursive scopes, style, styles[current]
    end
  end
  
  def add_style_from_textmate_theme name, settings
    style = {}
    style_names = name.split ','
    style_names.each do |sn|
      add_style_recursive sn.split('.'), style, @styles
    end
        
    if fs = settings['fontStyle']
      style[:bold] = fs =~ /bold/
      style[:italic] if fs =~ /italic/
      style[:underline] if fs =~ /underline/
    end
    if col = settings['foreground']
      style[:color] = hex_color_to_rtf col
      @colors << style[:color]
      style[:color_index] = @num_colors+=1
    end
    if col = settings['background']
      style[:bg_color] = hex_color_to_rtf col
      @colors << style[:bg_color]
      style[:bg_color_index] = @num_colors+=1
    end
  end
  
  def hex_color_to_rtf hex
    hex =~ /#(..)(..)(..)/
    r = $1.hex
    g = $2.hex
    b = $3.hex
    return "\\red#{r}\\green#{g}\\blue#{b};"
  end
  
  def generate_stylesheet_from_theme(theme_class = nil)
  	theme_class = '' if theme_class == nil
  	require "#{ENV['TM_SUPPORT_PATH']}/lib/plist"

  	# Load TM preferences to discover the current theme and font settings
  	textmate_pref_file = '~/Library/Preferences/com.macromates.textmate.plist'
  	prefs = PropertyList.load(File.open(File.expand_path(textmate_pref_file)))
  	theme_uuid = prefs['OakThemeManagerSelectedTheme']
  	# Load the active theme. Unfortunately, this requires us to scan through
  	# all discoverable theme files...
  	unless theme_plist = find_theme(theme_uuid)
  		print "Could not locate your theme file!"
  		abort
  	end

  	theme_comment = theme_plist['comment']
  	theme_name = theme_plist['name']
  	theme_class.replace(theme_name)
  	theme_class.downcase!
  	theme_class.gsub!(/[^a-z0-9_-]/, '_')
  	theme_class.gsub!(/_+/, '_')

  	@font_name = prefs['OakTextViewNormalFontName'] || 'Monaco'
  	@font_size = (prefs['OakTextViewNormalFontSize'] || 11).to_s
  	@font_size.sub! /\.\d+$/, ''
  	@font_size = @font_size.to_i * 3
  	
  	@font_name = '"' + @font_name + '"' if @font_name.include?(' ') &&
  		!@font_name.include?('"')

  	theme_plist['settings'].each do | setting |
  	  if (!setting['name'] and setting['settings'])
  			body_bg = setting['settings']['background'] || '#ffffff'
  			body_fg = setting['settings']['foreground'] || '#000000'
  			selection_bg = setting['settings']['selection']
  			body_bg = hex_color_to_rtf(body_bg)
  			body_fg = hex_color_to_rtf(body_fg)
  			selection_bg = hex_color_to_rtf(selection_bg) if selection_bg
  			@colors << body_fg
  			next
  		end
  	  if setting['name'] && setting['scope']
    		scope_name = setting['scope']
 	      add_style_from_textmate_theme scope_name, setting['settings']
 	    end
  	end
  end

  def color_table
    "{\\colortbl;#{@colors}}"
  end
  
  def font_table
    "{\\fonttbl {\\f0 #{@font_name};}}"
  end
  
  def rtf_document input
    <<-RTF_DOC
{\\rtf
#{font_table}
#{color_table}
{\\pard\\ql
\\f0\\fs#{@font_size} #{document_to_rtf input}
}}
RTF_DOC
  end
  
  # {\\rtf
  # #{font_table}
  # #{color_table}
  # {\\pard\\ql
  # \\f0\\fs#{@font_size}\\cf1\\b Hello, World!\\line
  # \\tab \\cf2 Next Line\\line
  # \\tab\\tab\\i \\cf3 Another line
  # }}
  
  # Search heuristic is based on the Theme Builder bundle's
  # "Create for Current Language" command
  def find_theme(uuid)
  	theme_dirs = [
  		File.expand_path('~/Library/Application Support/TextMate/Themes'),
  		'/Library/Application Support/TextMate/Themes',
  		TextMate.app_path + '/Contents/SharedSupport/Themes'
  	]

  	theme_dirs.each do |theme_dir|
  		if File.exists? theme_dir
  			themes = Dir.entries(theme_dir).find_all { |theme| theme =~ /.+\.(tmTheme|plist)$/ }
  			themes.each do |theme|
  				plist = PropertyList.load(File.open("#{theme_dir}/#{theme}"))
  				return plist if plist["uuid"] == uuid
  			end
  		end
  	end
  	return nil
  end
  
  def detab(str, width)
  	lines = str.split(/\n/)
  	lines.each do | line |
  		line_sans_markup = line #.gsub(/<[^>]*>/, '').gsub(/&[^;]+;/i, '.')
  		while (index = line_sans_markup.index("\t"))
  			tab = line_sans_markup[0..index].jlength - 1
  			padding = " " * ((tab / width + 1) * width - tab)
  			line_sans_markup.sub!("\t", padding)
  			line.sub!("\t", padding)
  		end
  	end
  	return lines.join("\n")
  end
  
  def document_to_rtf(input, opt = {})
  	# Read the source document / selection
  	# Convert tabs to spaces using configured tab width
  	input = detab(input, (ENV['TM_TAB_SIZE'] || '8').to_i)
  	input = input.gsub /\n/,"\\\\line\n"
  	
  	@style_stack = []

  	# Meat. The poor-man's tokenizer. Fortunately, our input is simple
  	# and easy to parse.
  	tokens = input.split(/(<[^>]*>)/)
  	code_rtf = ''
  	tokens.each do |token|
  		case token
  		when /^<\//
  		  # closing tag
  		  pop_style
  		when /^<>$/
  		  # skip empty tags, resulting from name = ''
  		when /^</
  		  if token =~ /^<([^>]+)>$/
  		    scope = $1
  		    push_style scope
  			end
  		else
  		  next if token.empty?
  		  code_rtf << '{'
  		  style = current_style_as_rtf
  		  if style && !style.empty? && !token.strip.empty?
  		    code_rtf << current_style_as_rtf << ' '
		    end
  			code_rtf << token.gsub(/\\/,'\\\\') << '}'
  		end
  	end
  	
  	return code_rtf
  end
  
  def current_style
    @style_stack[0] || {}
  end
  
  def get_style_recursive scopes, styles
    return nil unless styles
    cur = scopes.shift.strip
    style = nil
    unless scopes.empty?
      style = get_style_recursive(scopes, styles[cur]) || style
    end
    style = style || styles[:default]
    style
  end
  
  def current_style_as_rtf
    cur = current_style
    rtf = ''
    rtf << "\\cf#{cur[:color_index]}" if cur[:color_index]
    rtf << "\\cb1" if cur[:bg_color_index]
    rtf << "\\b" if cur[:bold]
    rtf << "\\i" if cur[:italic]
    rtf << "\\ul" if cur[:underline]
    rtf
  end
  
  def push_style name
    cur = current_style
    # p "getting #{name}"
    new_style = get_style_recursive(name.split('.'), @styles)
    # p "got #{new_style.inspect}"
    # p "current: #{cur.inspect}"
    new_style = cur.merge new_style if new_style
    new_style ||= {}
    unless new_style[:color_index]
      new_style[:color_index] = 0
    end
    # p "merged: #{new_style.inspect}"
    @style_stack.unshift new_style
    new_style
  end
  
  def pop_style
    @style_stack.shift
  end
  
end
