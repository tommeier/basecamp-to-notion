# /utils/file_reporter.rb

module FileReporter
  def self.manual_upload_files = $global_manual_upload_files

  def self.add(file_url, notion_page_id = nil, context = nil)
    manual_upload_files << {
      file_url: file_url,
      notion_page_id: notion_page_id,
      context: context
    }
  end

  def self.summary
    return if manual_upload_files.empty?

    puts "\n📎 Manual upload files:"
    manual_upload_files.each_with_index do |entry, idx|
      puts "#{idx + 1}. #{entry[:file_url]} (Page: #{entry[:notion_page_id]}, Context: #{entry[:context]})"
    end
  end
end
