# Debian 13 (trixie) ships FFmpeg 7.1.x; Atmos/DTS:X detection needs 7.1+.
FROM ruby:3.2-slim-trixie

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg build-essential \
 && rm -rf /var/lib/apt/lists/* \
 && ffmpeg -version | head -1 \
 && ffmpeg -version | grep -Eq 'version (7\.[1-9]|[89]\.|[1-9][0-9]\.)' \
    || { echo "ffmpeg 7.1+ required"; exit 1; }

WORKDIR /app
COPY Gemfile Gemfile.lock neutraliser.gemspec ./
COPY lib/neutraliser/version.rb lib/neutraliser/version.rb
RUN bundle config set --local without development:test \
 && bundle install

COPY bin bin
COPY lib lib
COPY README.md CHANGELOG.md LICENSE ./

# Mount the library at /media and pass `process /media/...`
WORKDIR /media
ENTRYPOINT ["bundle", "exec", "--gemfile=/app/Gemfile", "/app/bin/neutraliser"]
CMD ["--help"]
