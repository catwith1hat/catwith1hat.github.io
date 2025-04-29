FROM ruby:3.4

# Install required system packages
RUN apt-get update -qq && apt-get install -y build-essential nodejs

# Set working directory
WORKDIR /site

# Copy only Gemfile for caching
#COPY Gemfile Gemfile.lock ./
COPY Gemfile Gemfile.lock no-style-please.gemspec ./

# Install bundler and dependencies
RUN gem install bundler && bundle install

# Expose ports for Jekyll + livereload
EXPOSE 4000 35729

# Run Jekyll with livereload
CMD ["bundle", "exec", "jekyll", "serve", "--host", "0.0.0.0", "--livereload"]
