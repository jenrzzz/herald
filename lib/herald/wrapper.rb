require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"

module Herald
  # Herald.app: a signed bundle around a launcher (macos/launcher.c) that the
  # launchd agent starts instead of ruby, so that macOS files "may read the
  # Messages database" and "may control Messages" under something that stays
  # the same.
  #
  # The grants are kept against the bundle's designated requirement. Signed
  # with a certificate, that is `identifier "place.amber.herald" and
  # certificate leaf = H"..."`: no hash of the binary in it, so the launcher
  # can be rebuilt, and ruby upgraded underneath it, and the answer holds.
  #
  # With no HERALD_SIGN_IDENTITY the certificate is one herald makes for
  # itself: self-signed, in a keychain of its own under HERALD_HOME, beside a
  # file holding that keychain's password. The login keychain is never
  # opened and nothing prompts. The certificate is trusted by nobody and
  # does not need to be; its one job is to be the same next time. Lose the
  # keychain and the next build is a stranger to macOS, which asks again.
  class Wrapper
    BUNDLE_ID = "place.amber.herald".freeze
    OWN_IDENTITY = "Herald Code Signing".freeze
    SOURCES = File.expand_path("../../macos", __dir__)

    class Error < StandardError; end

    attr_reader :app

    def initialize(app: ENV.fetch("HERALD_APP", "~/Applications/Herald.app"), home: Herald.home, identity: ENV["HERALD_SIGN_IDENTITY"])
      @app = File.expand_path(app)
      @home = home
      @identity = identity.to_s.empty? ? nil : identity
    end

    # A shell that came in over ssh has a search list of its own, the system
    # keychain and nothing of the user's: there is no signing from there.
    def self.login_session?
      (keychains("-d", "user") & keychains).any?
    end

    def self.keychains(*domain)
      Open3.capture2e("security", "list-keychains", *domain).first.scan(/"([^"]+)"/).flatten
    rescue Errno::ENOENT
      []
    end

    def launcher
      File.join(app, "Contents/MacOS/herald")
    end

    def built?
      File.executable?(launcher) && run("codesign", "--verify", "--strict", app, fail: false).last
    end

    # Compiles, assembles and signs into a scratch directory, then swaps the
    # bundle into place: a build that fails leaves the old app as it was.
    def build
      Dir.mktmpdir("herald-app") do |scratch|
        staged = File.join(scratch, File.basename(app))
        FileUtils.mkdir_p(File.join(staged, "Contents/MacOS"))
        FileUtils.cp(File.join(SOURCES, "Info.plist"), File.join(staged, "Contents/Info.plist"))
        run("xcrun", "clang", "-O2", "-Wall", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0",
            "-o", File.join(staged, "Contents/MacOS/herald"), File.join(SOURCES, "launcher.c"))
        sign(staged)
        FileUtils.mkdir_p(File.dirname(app))
        FileUtils.rm_rf(app)
        FileUtils.mv(staged, app)
      end
      requirement
    end

    # What macOS will hold the grant against.
    def requirement
      run("codesign", "--display", "-r-", app).first[/^designated => (.*)$/, 1]
    end

    def keychain
      File.join(@home, "signing.keychain-db")
    end

    private

    def sign(bundle)
      command = [ "codesign", "--force", "--options", "runtime", "--entitlements", File.join(SOURCES, "herald.entitlements") ]
      return run(*command, "--sign", @identity, bundle) if @identity

      searchable { run(*command, "--keychain", keychain, "--sign", OWN_IDENTITY, bundle) }
    end

    # codesign finds an identity only in a keychain on the user's search
    # list, whatever --keychain says (macOS 26; 27 is more forgiving), and
    # the user's list only counts inside the login session. So herald's
    # keychain joins the list for as long as the signing takes, and the list
    # is put back exactly as it was. A list that cannot be read is not
    # rewritten: a wrong guess would drop the login keychain from it.
    def searchable
      listed = self.class.keychains("-d", "user")
      raise Error, "could not read the keychain search list, so it was left alone" if listed.empty?
      unless self.class.login_session?
        raise Error, "this shell is outside the login session (ssh?), where macOS will not use a keychain of yours: " \
                     "run bin/herald app in Terminal on the Mac itself"
      end
      unlock_keychain
      return yield if listed.include?(keychain)

      run("security", "list-keychains", "-d", "user", "-s", *listed, keychain)
      begin
        yield
      ensure
        run("security", "list-keychains", "-d", "user", "-s", *listed)
      end
    end

    # A keychain made outside the login session's list locks itself at every
    # logout, so it is unlocked each time rather than assumed open.
    def unlock_keychain
      create_identity unless File.exist?(keychain) && File.exist?(password_file)
      run("security", "unlock-keychain", "-p", password, keychain)
    end

    def create_identity
      FileUtils.mkdir_p(@home, mode: 0o700)
      FileUtils.rm_f(keychain)
      File.write(password_file, SecureRandom.hex(24), perm: 0o600)
      Dir.mktmpdir("herald-identity") do |dir|
        config, key, certificate, bundle = %w[cert.cnf key.pem cert.pem identity.p12].map { |name| File.join(dir, name) }
        File.write(config, <<~CNF)
          [req]
          distinguished_name = dn
          x509_extensions = ext
          prompt = no
          [dn]
          CN = #{OWN_IDENTITY}
          [ext]
          basicConstraints = critical,CA:false
          keyUsage = critical,digitalSignature
          extendedKeyUsage = critical,codeSigning
        CNF
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "7300", "-config", config, "-keyout", key, "-out", certificate)
        # -legacy: the keychain cannot read OpenSSL 3's default PKCS#12
        # encryption. LibreSSL (macOS's own openssl) has no such flag and
        # needs none.
        export = [ "openssl", "pkcs12", "-export", "-inkey", key, "-in", certificate, "-name", OWN_IDENTITY, "-passout", "pass:#{password}", "-out", bundle ]
        run(*export, "-legacy", fail: false).last or run(*export)
        run("security", "create-keychain", "-p", password, keychain)
        run("security", "set-keychain-settings", keychain)
        run("security", "unlock-keychain", "-p", password, keychain)
        run("security", "import", bundle, "-k", keychain, "-P", password, "-T", "/usr/bin/codesign")
        # Without this codesign's first use of the key would stop to ask.
        run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain)
      end
    end

    def password_file
      File.join(@home, "signing.password")
    end

    def password
      File.read(password_file).strip
    end

    # [ output, succeeded ]; raises unless told a failure is an answer. The
    # keychain's password rides in argv, so it is kept out of the message.
    def run(*command, fail: true)
      output, status = Open3.capture2e(*command)
      raise Error, "#{command.first(2).join(' ')} failed: #{output.strip[0, 400]}" if fail && !status.success?

      [ output, status.success? ]
    rescue Errno::ENOENT
      raise Error, "#{command.first} is not installed#{' (xcode-select --install)' if command.first == 'xcrun'}"
    end
  end
end
