require 'core/project'
require 'core/compile'
require 'java/artifact'

module Buildr
  # Methods added to Project to support packaging and tasks for packaging,
  # installing and uploading packages.
  module Package

    include Extension

    first_time do
      desc 'Create packages'
      Project.local_task('package'=>'build') { |name| "Packaging #{name}" }
      desc 'Install packages created by the project'
      Project.local_task('install'=>'package') { |name| "Installing packages from #{name}" }
      desc 'Remove previously installed packages'
      Project.local_task('uninstall') { |name| "Uninstalling packages from #{name}" }
      desc 'Upload packages created by the project'
      Project.local_task('upload'=>'package') { |name| "Deploying packages from #{name}" }
      # Anything that comes after local packaging (install, deploy) executes the integration tests,
      # which do not conflict with integration invoking the project's own packaging (package=>
      # integration=>foo:package is not circular, just confusing to debug.)
      task 'package' do
        task('integration').invoke if Buildr.options.test && Rake.application.original_dir == Dir.pwd
      end
    end

    before_define do |project|
      [ :package, :install, :uninstall, :upload ].each { |name| project.recursive_task name }
      # Need to run build before package, since package is often used as a dependency by tasks that
      # expect build to happen.
      project.task('package'=>project.task('build'))
      project.group ||= project.parent && project.parent.group || project.name
      project.version ||= project.parent && project.parent.version
    end

    # The project's identifier. Same as the project name, with colons replaced by dashes.
    # The ID for project foo:bar is foo-bar.
    def id
      name.gsub(':', '-')
    end

    # Group used for packaging. Inherited from parent project. Defaults to the top-level project name.
    attr_accessor :group

    # Version used for packaging. Inherited from parent project.
    attr_accessor :version

    # :call-seq:
    #   package(type, spec?) => task
    #
    # Defines and returns a package created by this project.
    #
    # The first argument declares the package type. For example, :jar to create a JAR file.
    # The package is an artifact that takes its artifact specification from the project.
    # You can override the artifact specification by passing various options in the second
    # argument, for example:
    #   package(:zip, :classifier=>'sources')
    #
    # Packages that are ZIP files provides various ways to include additional files, directories,
    # and even merge ZIPs together. Have a look at ZipTask for more information. In case you're
    # wondering, JAR and WAR packages are ZIP files.
    #
    # You can also enhance a JAR package using the ZipTask#with method that accepts the following options:
    # * :manifest -- Specifies how to create the MANIFEST.MF. By default, uses the project's
    #   #manifest property.
    # * :meta_inf -- Specifies files to be included in the META-INF directory. By default,
    #   uses the project's #meta-inf property.
    #
    # The WAR package supports the same options and adds a few more:
    # * :classes -- Directories of class files to include in WEB-INF/classes. Includes the compile
    #   target directory by default.
    # * :libs -- Artifacts and files to include in WEB-INF/libs. Includes the compile classpath
    #   dependencies by default.
    #
    # For example:
    #   define 'project' do
    #     define 'beans' do
    #       package :jar
    #     end
    #     define 'webapp' do
    #       compile.with project('beans')
    #       package(:war).with :libs=>MYSQL_JDBC
    #     end
    #     package(:zip, :classifier=>'sources').include path_to('.')
    #  end
    #
    # Two other packaging types are:
    # * package :sources -- Creates a ZIP file with the source code and classifier 'sources', for use by IDEs.
    # * package :javadoc -- Creates a ZIP file with the Javadocs and classifier 'javadoc'. You can use the
    #   javadoc method to further customize it.
    #
    # A package is also an artifact. The following tasks operate on packages created by the project:
    #   buildr upload     # Upload packages created by the project
    #   buildr install    # Install packages created by the project
    #   buildr package    # Create packages
    #   buildr uninstall  # Remove previously installed packages
    #
    # If you want to add additional packaging types, implement a method with the name package_as_[type]
    # that accepts a file name and returns an appropriate Rake task.  For example:
    #   def package_as_zip(file_name) #:nodoc:
    #     ZipTask.define_task(file_name)
    #   end
    #
    # The file name is determined from the specification passed to the package method, however, some
    # packagers need to override this.  For example, package(:sources) produces a file with the extension
    # 'zip' and the classifier 'sources'.  If you need to overwrite the default implementation, you should
    # also include a method named package_as_[type]_respec.  For example:
    #   def package_as_sources_spec(spec) #:nodoc:
    #     { :type=>:zip, :classifier=>'sources' }.merge(spec)
    #   end
    def package(type = nil, spec = nil)
      spec = spec.nil? ? {} : spec.dup
      type ||= compile.packaging || :zip
      rake_check_options spec, *ActsAsArtifact::ARTIFACT_ATTRIBUTES
      spec[:id] ||= self.id
      spec[:group] ||= self.group
      spec[:version] ||= self.version
      spec[:type] ||= type

      packager = method("package_as_#{type}") rescue
        fail("Don't know how to create a package of type #{type}")
      if packager.arity == 1
        spec = send("package_as_#{type}_spec", spec) if respond_to?("package_as_#{type}_spec")
        file_name = path_to(:target, Artifact.hash_to_file_name(spec))
        package = Rake::Task[file_name] rescue packager.call(file_name)
      else
        warn_deprecated "We changed the way package_as methods are implemented.  See the package method documentation for more details."
        file_name = path_to(:target, Artifact.hash_to_file_name(spec))
        package = packager.call(file_name, spec)
      end
      unless packages.include?(package)
        # Make it an artifact using the specifications, and tell it how to create a POM.
        package.extend ActsAsArtifact
        package.send :apply_spec, spec.only(*Artifact::ARTIFACT_ATTRIBUTES)
        # Another task to create the POM file.
        pom = package.pom
        pom.enhance do
          mkpath File.dirname(pom.name), :verbose=>false
          File.open(pom.name, 'w') { |file| file.write pom.pom_xml }
        end

        # We already run build before package, but we also need to do so if the package itself is
        # used as a dependency, before we get to run the package task.
        task 'package'=>package
        package.enhance [task('build')]

        # Install the artifact along with its POM. Since the artifact (package task) is created
        # in the target directory, we need to copy it into the local repository. However, the
        # POM artifact (created by calling artifact on its spec) is already mapped to its right
        # place in the local repository, so we only need to invoke it.
        installed = file(Buildr.repositories.locate(package)=>package) { |task|
          verbose(Rake.application.options.trace || false) do
            mkpath File.dirname(task.name), :verbose=>false
            cp package.name, task.name
          end
          puts "Installed #{task.name}" if verbose
        }
        task 'install'=>[installed, pom]
        task 'uninstall' do |task|
          verbose(Rake.application.options.trace || false) do
            [ installed, pom ].map(&:to_s).each { |file| rm file if File.exist?(file) } 
          end
        end
        task('upload') { package.pom.invoke ; package.pom.upload ; package.upload }

        # Add the package to the list of packages created by this project, and
        # register it as an artifact. The later is required so if we look up the spec
        # we find the package in the project's target directory, instead of finding it
        # in the local repository and attempting to install it.
        packages << package
        Artifact.register package, pom
      end
      package
    end

    # :call-seq:
    #   packages => tasks
    #
    # Returns all packages created by this project. A project may create any number of packages.
    #
    # This method is used whenever you pass a project to Buildr#artifact or any other method
    # that accepts artifact specifications and projects. You can use it to list all packages
    # created by the project. If you want to return a specific package, it is often more
    # convenient to call #package with the type.
    def packages
      @packages ||= []
    end

  protected

    def package_as_zip(file_name) #:nodoc:
      ZipTask.define_task(file_name)
    end

    def package_as_tar(file_name) #:nodoc:
      TarTask.define_task(file_name)
    end
    alias :package_as_tgz :package_as_tar

    def package_as_sources_spec(spec) #:nodoc:
      spec.merge(:type=>:zip, :classifier=>'sources')
    end

    def package_as_sources(file_name) #:nodoc:
      ZipTask.define_task(file_name).tap do |zip|
        zip.include :from=>compile.sources
      end
    end

  end
end