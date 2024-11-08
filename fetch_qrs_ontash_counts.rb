require 'googleauth'
require 'rest-client'
require 'json'
require 'yaml'
require 'logger'
require 'date'
require 'write_xlsx'

# Setup logging to a file
log_file_path = File.join(Dir.pwd, "script_log.log")
logger = Logger.new(log_file_path)
logger.level = Logger::DEBUG # Log everything from DEBUG level and above

logger.info("Script started at #{Time.now}")

# Function to load credentials from JSON key file
def load_authorizer(key_path, scope, logger)
  begin
    authorizer = Google::Auth::ServiceAccountCredentials.make_creds(json_key_io: File.open(key_path), scope: scope)
    authorizer.fetch_access_token!
    logger.info("Access token fetched successfully for key: #{key_path}")
    authorizer.access_token
  rescue StandardError => e
    logger.error("Error fetching access token: #{e.message}")
    nil
  end
end

# Define a function to calculate date ranges for the previous full week (Sunday to Saturday) and previous full month
def calculate_date_ranges(logger)
  today = Date.today
  
  # Calculate the previous full week (Sunday to Saturday)
  last_saturday = today - today.wday - 1
  last_sunday = last_saturday - 6
  
  # Calculate the previous full month
  first_day_last_month = Date.new(today.year, today.month - 1, 1)
  last_day_last_month = (first_day_last_month.next_month - 1)

  logger.info("Date ranges calculated successfully")
  {
    previous_week: { start_date: last_sunday.strftime('%Y-%m-%d'), end_date: last_saturday.strftime('%Y-%m-%d') },
    previous_month: { start_date: first_day_last_month.strftime('%Y-%m-%d'), end_date: last_day_last_month.strftime('%Y-%m-%d') }
  }
end

# Helper method to format time in seconds to 'Xm Ys' format
def format_time(seconds)
  rounded_seconds = seconds.round
  if rounded_seconds < 60
    "#{rounded_seconds}s"
  else
    minutes = (rounded_seconds / 60).floor
    remaining_seconds = (rounded_seconds % 60)
    "#{minutes}m #{remaining_seconds}s"
  end
end

# Function to fetch metrics from Google Analytics
def fetch_engagement_metrics(access_token, property_id, start_date, end_date, logger)
  request_body = {
    property: "properties/#{property_id}",
    metrics: [
      { name: 'userEngagementDuration' },
      { name: 'totalUsers' },
      { name: 'newUsers' },
      { name: 'sessions' },
      { name: 'screenPageViews' },
      { name: 'eventCount' }
    ],
    dateRanges: [{ startDate: start_date, endDate: end_date }]
  }.to_json

  begin
    response = RestClient.post(
      "https://analyticsdata.googleapis.com/v1beta/properties/#{property_id}:runReport",
      request_body,
      { Authorization: "Bearer #{access_token}", content_type: :json, accept: :json }
    )

    data = JSON.parse(response.body)

    if data['rows'] && !data['rows'].empty?
      logger.info("Data fetched successfully for property: #{property_id}")

      user_engagement_duration = data['rows'][0]['metricValues'][0]['value'].to_f
      total_users = data['rows'][0]['metricValues'][1]['value'].to_f
      new_users = data['rows'][0]['metricValues'][2]['value'].to_f
      sessions = data['rows'][0]['metricValues'][3]['value'].to_f
      page_views = data['rows'][0]['metricValues'][4]['value'].to_f
      event_count = data['rows'][0]['metricValues'][5]['value'].to_f

      formatted_engagement_time = sessions > 0 ? format_time(user_engagement_duration / sessions) : "No sessions"

      return formatted_engagement_time, total_users, new_users, sessions, page_views, event_count
    else
      logger.warn("No data found for property: #{property_id}")
      return nil
    end
  rescue RestClient::ExceptionWithResponse => e
    logger.error("Failed to fetch data: #{e.message}")
    return nil
  end
end

# Main function to handle both Ontash and QRS event counts
def process_event_counts(site_name, key_path, property_id, logger)
  scope = 'https://www.googleapis.com/auth/analytics.readonly'
  access_token = load_authorizer(key_path, scope, logger)

  unless access_token
    logger.error("Could not obtain access token for #{site_name}. Skipping...")
    return nil
  end

  # Get date ranges for the previous week and month
  date_ranges = calculate_date_ranges(logger)

  # Fetch metrics for the previous week and month
  formatted_engagement_time, total_users, new_users, sessions, page_views, event_count = fetch_engagement_metrics(access_token, property_id, date_ranges[:previous_week][:start_date], date_ranges[:previous_week][:end_date], logger)
  formatted_engagement_time_month, total_users_month, new_users_month, sessions_month, page_views_month, event_count_month = fetch_engagement_metrics(access_token, property_id, date_ranges[:previous_month][:start_date], date_ranges[:previous_month][:end_date], logger)

  # Return the metrics as a hash for Excel generation
  if formatted_engagement_time && total_users
    logger.info("Metrics processed successfully for #{site_name}")
    {
      site_name: site_name,
      total_users: total_users,
      total_users_month: total_users_month,
      new_users: new_users,
      new_users_month: new_users_month,
      sessions: sessions,
      sessions_month: sessions_month,
      page_views: page_views,
      page_views_month: page_views_month,
      event_count: event_count,
      event_count_month: event_count_month,
      formatted_engagement_time: formatted_engagement_time,
      formatted_engagement_time_month: formatted_engagement_time_month
    }
  else
    logger.error("Metrics could not be processed for #{site_name}.")
    nil
  end
end

# Create Excel report
def generate_excel_report(results, logger)
  file_path = File.join(Dir.pwd, "website_performance_report.xlsx")
  
  workbook = WriteXLSX.new(file_path)
  worksheet = workbook.add_worksheet

  # Add headers
  headers = ["Website", "Users (Last Month)", "Users (Previous Week)", "New Users (Last Month)", "New Users (Previous Week)", "Sessions (Last Month)", "Sessions (Previous Week)", "Page Views (Last Month)", "Page Views (Previous Week)", "Event Count (Last Month)", "Event Count (Previous Week)", "Average Engagement Time (Last Month)", "Average Engagement Time (Previous Week)"]
  headers.each_with_index do |header, index|
    worksheet.write(0, index, header)
  end

  # Write data
  results.each_with_index do |data, row|
    next if data.nil? # Skip nil data

    worksheet.write(row + 1, 0, data[:site_name])
    worksheet.write(row + 1, 1, data[:total_users_month])
    worksheet.write(row + 1, 2, data[:total_users])
    worksheet.write(row + 1, 3, data[:new_users_month])
    worksheet.write(row + 1, 4, data[:new_users])
    worksheet.write(row + 1, 5, data[:sessions_month])
    worksheet.write(row + 1, 6, data[:sessions])
    worksheet.write(row + 1, 7, data[:page_views_month])
    worksheet.write(row + 1, 8, data[:page_views])
    worksheet.write(row + 1, 9, data[:event_count_month])
    worksheet.write(row + 1, 10, data[:event_count])
    worksheet.write(row + 1, 11, data[:formatted_engagement_time_month])
    worksheet.write(row + 1, 12, data[:formatted_engagement_time])
  end

  workbook.close
  logger.info("Excel report generated successfully at: #{file_path}")
end

# Fetch data for both Ontash and QRS
ontash_results = process_event_counts("ontash.net", 'C:/fetch_qrs_ontash_event_count_excel_to_mail/ontash-count-720ab8d8e227.json', '365721410', logger)
qrs_results = process_event_counts("qualityreimbursement.com", 'C:/fetch_qrs_ontash_event_count_excel_to_mail/qrs-count-d6d81a7baa89.json', '365772232', logger)

# Combine results
all_results = [ontash_results, qrs_results]

# Filter out nil results (if any)
filtered_results = all_results.compact

if filtered_results.any?
  # Generate Excel report
  generate_excel_report(filtered_results, logger)
else
  logger.error("No valid data found to generate report.")
end

logger.info("Script finished at #{Time.now}")
