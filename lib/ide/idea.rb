require "pathname"
require "core/project"
require "java/artifact"
require 'stringio'
require 'rexml/document'

module Buildr
  module Idea #:nodoc:

    include Extension

    first_time do
      # Global task "idea" generates artifacts for all projects.
      desc "Generate Idea artifacts for all projects"
      Project.local_task "idea"=>"artifacts"
    end

    before_define do |project|
      project.recursive_task("idea")
    end

    after_define do |project|
      idea = project.task("idea")
      # We need paths relative to the top project's base directory.
      root_path = lambda { |p| f = lambda { |p| p.parent ? f[p.parent] : p.base_dir } ; f[p] }[project]
      # We want the Eclipse files changed every time the Buildfile changes, but also anything loaded by
      # the Buildfile (buildr.rb, separate file listing dependencies, etc), so we add anything required
      # after the Buildfile. So which don't know where Buildr shows up exactly, ignore files that show
      # in $LOADED_FEATURES that we cannot resolve.
      sources = Buildr.build_files.map { |file| File.expand_path(file) }.select { |file| File.exist?(file) }
      sources << File.expand_path(Rake.application.rakefile, root_path) if Rake.application.rakefile

      # Find a path relative to the project's root directory.
      relative = lambda do |path|
        msg = [:to_path, :to_str, :to_s].find { |msg| path.respond_to? msg }
        path = path.__send__(msg)
        Pathname.new(path).relative_path_from(Pathname.new(project.path_to)).to_s
      end

      m2repo = Buildr::Repositories.instance.local
      excludes = [ '**/.svn/', '**/CVS/' ].join('|')

      # Only for projects that are packageable.
      task_name = project.path_to("#{project.name.gsub(':', '-')}.iml")
      idea.enhance [ file(task_name) ]

      # The only thing we need to look for is a change in the Buildfile.
      file(task_name=>sources) do |task|
        puts "Writing #{task.name}" if verbose

        # Idea handles modules slightly differently if they're WARs
        idea_types = Hash.new("JAVA_MODULE")
        idea_types["war"] = "J2EE_WEB_MODULE"

        # Note: Use the test classpath since Eclipse compiles both "main" and "test" classes using the same classpath
        cp = project.test.compile.classpath.map(&:to_s) - [ project.compile.target.to_s ]

        # Convert classpath elements into applicable Project objects
        cp.collect! { |path| projects.detect { |prj| prj.packages.detect { |pkg| pkg.to_s == path } } || path }

        # project_libs: artifacts created by other projects
        project_libs, others = cp.partition { |path| path.is_a?(Project) }

        # Separate artifacts from Maven2 repository
        m2_libs, others = others.partition { |path| path.to_s.index(m2repo) == 0 }

        # Generated: classpath elements in the project are assumed to be generated
        generated, libs = others.partition { |path| path.to_s.index(project.path_to.to_s) == 0 }

        File.open(task.name, "w") do |file|
          xml = Builder::XmlMarkup.new(:target=>file, :indent=>2)
          # Project type is going to be the first package type
          xml.module(:version=>"4", :relativePaths=>"false", :type=>idea_types[project.packages.first.type.to_s]) do

            xml.component :name=>"ModuleRootManager"
            xml.component "name"=>"NewModuleRootManager", "inherit-compiler-output"=>"false" do
              xml.output :url=>"file://$MODULE_DIR$/#{relative[project.compile.target]}"
              xml.tag! "exclude-output"

              # TODO project.test.target isn't recognized, what's the proper way to get the test compile path?
              xml.tag! "output-test", :url=>"file://$MODULE_DIR$/target/test-classes"

              xml.content(:url=>"file://$MODULE_DIR$") do
                srcs = project.compile.sources.map { |src| relative[src] } + generated.map { |src| relative[src] }
                srcs.sort.uniq.each do |path|
                  xml.sourceFolder :url=>"file://$MODULE_DIR$/#{path}", :isTestSource=>"false"
                end
                test_sources = project.test.compile.sources.map { |src| relative[src] }
                test_sources.each do |paths|
                  paths.sort.uniq.each do |path|
                    xml.sourceFolder :url=>"file://$MODULE_DIR$/#{path}", :isTestSource=>"true"
                  end
                end
                [project.resources=>false, project.test.resources=>true].each do |resources, test|
                  resources.sources.each do |path|
                    xml.sourceFolder :url=>"file://$MODULE_DIR$/#{path}", :isTestSource=>test.to_s
                  end
                end
                xml.excludeFolder :url=>"file://$MODULE_DIR$/#{relative[project.compile.target]}"
              end

              xml.orderEntry :type=>"sourceFolder", :forTests=>"false"
              xml.orderEntry :type=>"inheritedJdk"

              # Classpath elements from other projects
              project_libs.map(&:id).sort.uniq.each do |project_id|
                xml.orderEntry :type=>'module', "module-name"=>project_id
              end

              # Libraries
              ext_libs = libs.map {|path| "$MODULE_DIR$/#{path.to_s}" } + 
              m2_libs.map { |path| path.to_s.sub(m2repo, "$M2_REPO$") }                  
              ext_libs.each do |path|
                xml.orderEntry :type=>"module-library" do
                  xml.library do
                    xml.CLASSES do
                      xml.root :url=>"jar://#{path}!/"
                    end
                    xml.JAVADOC
                    xml.SOURCES
                  end
                end
              end

              xml.orderEntryProperties
            end
          end
        end
      end

      # Root project aggregates all the subprojects.
      if project.parent == nil
        task_name = project.path_to("#{project.name.gsub(':', '-')}.ipr")
        idea.enhance [ file(task_name) ]

        file(task_name=>sources) do |task|
          puts "Writing #{task.name}" if verbose

          # Generating just the little stanza that chanages from one project to another
          partial = StringIO.new
          xml = Builder::XmlMarkup.new(:target=>partial, :indent=>2)
          xml.component(:name=>"ProjectModuleManager") do
            xml.modules do
              project.projects.each do |subp|
                module_name = subp.name.gsub(":", "-")
                module_path = subp.name.split(":"); module_path.shift
                module_path = module_path.join("/")
                path = "#{module_path}/#{module_name}.iml"
                xml.module :fileurl=>"file://$PROJECT_DIR$/#{path}", :filepath=>"$PROJECT_DIR$/#{path}"
              end
              xml.module :fileurl=>"file://$PROJECT_DIR$/#{project.name}.iml", :filepath=>"$PROJECT_DIR$/#{project.name}.iml"
            end
          end

          # Loading the whole fairly constant crap
          template_xml = REXML::Document.new(File.open(File.dirname(__FILE__)+"/idea.ipr.template"))
          include_xml = REXML::Document.new(partial.string)
          template_xml.root.add_element(include_xml.root)
          template_xml.write(File.new(task.name, "w"))

        end
      end

    end

  end
end # module Buildr