MSSQL_CONFIG = {
  :host     => "192.168.209.101",
  :username => 'sa',
  :password => 'sa',
  :adapter  => 'mssql',
  :database => 'weblog_development'
}
MSSQL_CONFIG[:host] = ENV['SQLHOST'] if ENV['SQLHOST']

ActiveRecord::Base.establish_connection(MSSQL_CONFIG)
