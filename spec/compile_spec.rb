require File.join(File.dirname(__FILE__), 'spec_helpers')


module CompilerHelper
  def compile_task
    @compile_task ||= define('foo').compile.using(:javac)
  end

  def sources
    @sources ||= ['Test1.java', 'Test2.java'].map { |f| File.join('src/java', f) }.
      each { |src| write src, "class #{src.pathmap('%n')} {}" }
  end

  def jars
    @jars ||= begin
      write 'src/main/java/Dependency.java', 'class Dependency { }'
      define 'jars', :version=>'1.0' do
        compile.into('dependency')
        package(:jar, :id=>'jar1')
        package(:jar, :id=>'jar2')
      end
      project('jars').packages.each(&:invoke).map(&:to_s)
    end
  end
end


describe Buildr::CompileTask do
  include CompilerHelper

  it 'should respond to from() and return self' do
    compile_task.from(sources).should be(compile_task)
  end

  it 'should respond to from() and add sources' do
    compile_task.from sources, File.dirname(sources.first)
    compile_task.sources.should == sources + [File.dirname(sources.first)]
  end

  it 'should respond to with() and return self' do
    compile_task.with('test.jar').should be(compile_task)
  end

  it 'should respond to with() and add classpath dependencies' do
    jars = (1..3).map { |i| "test#{i}.jar" }
    compile_task.with *jars
    compile_task.classpath.should == artifacts(jars)
  end

  it 'should respond to into() and return self' do
    compile_task.into('code').should be(compile_task)
  end

  it 'should respond to into() and create file task' do
    compile_task.from(sources).into('code')
    lambda { file('code').invoke }.should run_task('foo:compile')
  end

  it 'should respond to using() and return self' do
    compile_task.using(:source=>'1.4').should eql(compile_task)
  end

  it 'should respond to using() and set options' do
    compile_task.using(:source=>'1.4', 'target'=>'1.5')
    compile_task.options.source.should eql('1.4')
    compile_task.options.target.should eql('1.5')
  end

  it 'should attempt to identify compiler' do
    Compiler.compilers.first.should_receive(:applies_to?).at_least(:once)
    define('foo')
  end

  it 'should only support existing compilers' do
    lambda { define('foo') { compile.using(:unknown) } }.should raise_error(ArgumentError, /unknown compiler/i)
  end

  it 'should only allow setting the compiler once' do
    lambda { define('foo') { compile.using(:javac).using(:scalac) } }.should raise_error(RuntimeError, /already selected/i)
  end
end


describe Buildr::CompileTask, '#compiler' do
  it 'should be nil if no compiler identifier' do
    define('foo').compile.compiler.should be_nil
  end
  
  it 'should return the selected compiler' do
    define('foo') { compile.using(:javac) }
    project('foo').compile.compiler.should eql(:javac)
  end

  it 'should attempt to identify compiler if sources are specified' do
    define 'foo' do
      Compiler.compilers.first.should_receive(:applies_to?)
      compile.from('sources').compiler
    end
  end
end


describe Buildr::CompileTask, '#language' do
  it 'should be nil if no compiler identifier' do
    define('foo').compile.language.should be_nil
  end
  
  it 'should return the appropriate language' do
    define('foo') { compile.using(:javac) }
    project('foo').compile.language.should eql(:java)
  end
end


describe Buildr::CompileTask, '#sources' do
  include CompilerHelper

  it 'should be empty if no sources in default directory' do
    compile_task.sources.should be_empty
  end

  it 'should point to default directory if it contains sources' do
    write 'src/main/java', ''
    compile_task.sources.first.should point_to_path('src/main/java')
  end

  it 'should be an array' do
    compile_task.sources += sources
    compile_task.sources.should == sources
  end

  it 'should allow files' do
    compile_task.from(sources).into('classes').invoke
    sources.each { |src| file(src.pathmap('classes/%n.class')).should exist }
  end

  it 'should allow directories' do
    compile_task.from(File.dirname(sources.first)).into('classes').invoke
    sources.each { |src| file(src.pathmap('classes/%n.class')).should exist }
  end

  it 'should allow tasks' do
    lambda { compile_task.from(file(sources.first)).into('classes').invoke }.should run_task('foo:compile')
  end

  it 'should act as prerequisites' do
    file('src2') { |task| task('prereq').invoke ; mkpath task.name }
    lambda { compile_task.from('src2').into('classes').invoke }.should run_task('prereq')
  end
end


describe Buildr::CompileTask, '#dependencies' do
  include CompilerHelper

  it 'should be empty' do
    compile_task.dependencies.should be_empty
  end

  it 'should be an array' do
    compile_task.dependencies += jars
    compile_task.dependencies.should == jars
  end

  it 'should allow files' do
    compile_task.from(sources).with(jars).into('classes').invoke
    sources.each { |src| file(src.pathmap('classes/%n.class')).should exist }
  end

  it 'should allow tasks' do
    compile_task.from(sources).with(file(jars.first)).into('classes').invoke
  end

  it 'should allow artifacts' do
    artifact('group:id:jar:1.0') { |task| mkpath File.dirname(task.to_s) ; cp jars.first.to_s, task.to_s }
    compile_task.from(sources).with('group:id:jar:1.0').into('classes').invoke
  end

  it 'should allow projects' do
    define('bar', :version=>'1', :group=>'self') { package :jar }
    compile_task.with project('bar')
    compile_task.dependencies.should == project('bar').packages
  end

  it 'should be accessible as classpath' do
    lambda { compile_task.classpath = jars }.should change(compile_task, :dependencies).to(jars)
    lambda { compile_task.dependencies = [] }.should change(compile_task, :classpath).to([])
  end

end


describe Buildr::CompileTask, '#target' do
  include CompilerHelper

  it 'should be a file task' do
    compile_task.from(@sources).into('classes')
    compile_task.target.should be_kind_of(Rake::FileTask)
  end

  it 'should accept a task' do
    task = file('classes')
    compile_task.into(task).target.should be(task)
  end

  it 'should create dependency in file task when set' do
    compile_task.from(sources).into('classes')
    lambda { file('classes').invoke }.should run_task('foo:compile')
  end
end


describe Buildr::CompileTask, '#options' do
  include CompilerHelper

  it 'should have getter and setter methods' do
    compile_task.options.foo = 'bar'
    compile_task.options.foo.should eql('bar')
  end
  
  it 'should have bracket accessors' do
    compile_task.options[:foo] = 'bar'
    compile_task.options[:foo].should eql('bar')
  end

  it 'should map from bracket accessor to get/set accessor' do
    compile_task.options[:foo] = 'bar'
    compile_task.options.foo.should eql('bar')
  end

  it 'should be independent of parent' do
    define 'foo' do
      compile.using(:javac, :source=>'1.4')
      define 'bar' do
        compile.using(:javac, :source=>'1.5')
      end
    end
    project('foo').compile.options.source.should eql('1.4')
    project('foo:bar').compile.options.source.should eql('1.5')
  end
end


describe Buildr::CompileTask, '#invoke' do
  include CompilerHelper

  it 'should compile into target directory' do
    compile_task.from(sources).into('code').invoke
    Dir['code/*.class'].should_not be_empty
  end

  it 'should compile only once' do
    compile_task.from(sources)
    lambda { compile_task.target.invoke }.should run_task('foo:compile')
    lambda { compile_task.invoke }.should_not run_task('foo:compile')
  end

  it 'should compile if there are source files to compile' do
    lambda { compile_task.from(sources).invoke }.should run_task('foo:compile')
  end

  it 'should not compile unless there are source files to compile' do
    lambda { compile_task.invoke }.should_not run_task('foo:compile')
  end

  it 'should require source file or directory to exist' do
    lambda { compile_task.from('empty').into('classes').invoke }.should raise_error(RuntimeError, /Don't know how to build/)
  end

  it 'should run all source files as prerequisites' do
    file(mkpath('src')).should_receive :invoke_prerequisites
    compile_task.from('src').invoke
  end

  it 'should require dependencies to exist' do
    lambda { compile_task.from(sources).with('no-such.jar').into('classes').invoke }.should \
      raise_error(RuntimeError, /Don't know how to build/)
  end

  it 'should run all dependencies as prerequisites' do
    file(File.expand_path('no-such.jar')) { |task| task('prereq').invoke }
    lambda { compile_task.from(sources).with('no-such.jar').into('classes').invoke }.should run_tasks(['prereq', 'foo:compile'])
  end

  it 'should force compilation if no target' do
    lambda { compile_task.from(sources).invoke }.should run_task('foo:compile')
  end

  it 'should force compilation if target empty' do
    mkpath compile_task.target.to_s
    lambda { compile_task.from(sources).invoke }.should run_task('foo:compile')
  end

  it 'should force compilation if sources newer than compiled' do
    # Simulate class files that are older than source files.
    time = Time.now
    sources.each { |src| File.utime(time + 1, time + 1, src) }
    sources.map { |src| src.pathmap("#{compile_task.target}/%n.class") }.
      each { |kls| write kls ; File.utime(time, time, kls) }
    lambda { compile_task.from(sources).invoke }.should run_task('foo:compile')
  end

  it 'should not force compilation if sources older than compiled' do
    # When everything has the same timestamp, nothing is compiled again.
    time = Time.now
    sources.map { |src| src.pathmap("#{compile_task.target}/%n.class") }.
      each { |kls| write kls ; File.utime(time, time, kls) }
    lambda { compile_task.from(sources).invoke }.should_not run_task('foo:compile')
  end

  it 'should force compilation if dependencies newer than compiled' do
    # On my machine the times end up the same, so need to push dependencies in the past.
    time = Time.now
    sources.map { |src| src.pathmap("#{compile_task.target}/%n.class") }.
      each { |kls| write kls ; File.utime(time, time, kls) }
    jars.each { |jar| File.utime(time + 1, time + 1, jar) }
    lambda { compile_task.from(sources).with(jars).invoke }.should run_task('foo:compile')
  end

  it 'should not force compilation if dependencies older than compiled' do
    time = Time.now
    sources.map { |src| src.pathmap("#{compile_task.target}/%n.class") }.
      each { |kls| write kls ; File.utime(time, time, kls) }
    jars.each { |jar| File.utime(time - 1, time - 1, jar) }
    lambda { compile_task.from(sources).with(jars).invoke }.should_not run_task('foo:compile')
  end

  it 'should timestamp target directory if specified' do
    time = Time.now - 10
    mkpath compile_task.target.to_s
    File.utime(time, time, compile_task.target.to_s)
    compile_task.timestamp.should be_close(time, 1)
  end

  it 'should touch target if anything compiled' do
    mkpath compile_task.target.to_s
    File.utime(Time.now - 10, Time.now - 10, compile_task.target.to_s)
    compile_task.from(sources).invoke
    File.stat(compile_task.target.to_s).mtime.should be_close(Time.now, 2)
  end

  it 'should not touch target if nothing compiled' do
    mkpath compile_task.target.to_s
    File.utime(Time.now - 10, Time.now - 10, compile_task.target.to_s)
    compile_task.invoke
    File.stat(compile_task.target.to_s).mtime.should be_close(Time.now - 10, 2)
  end

  it 'should not touch target if failed to compile' do
    mkpath compile_task.target.to_s
    File.utime(Time.now - 10, Time.now - 10, compile_task.target.to_s)
    write 'failed.java', 'not a class'
    suppress_stdout { compile_task.from('failed.java').invoke rescue nil }
    File.stat(compile_task.target.to_s).mtime.should be_close(Time.now - 10, 2)
  end

  it 'should complain if source directories and no compiler selected' do
    mkpath 'sources'
    define 'bar' do
      lambda { compile.from('sources').invoke }.should raise_error(RuntimeError, /no compiler selected/i)
    end
  end
end


describe 'accessor task', :shared=>true do
  it 'should return a task' do
    define('foo').send(@task_name).should be_kind_of(Rake::Task)
  end

  it 'should always return the same task' do
    task_name, task = @task_name, nil
    define('foo') { task = self.send(task_name) }
    project('foo').send(task_name).should be(task)
  end

  it 'should be unique for the project' do
    define('foo') { define 'bar' }
    project('foo').send(@task_name).should_not eql(project('foo:bar').send(@task_name))
  end

  it 'should be named after the project' do
    define('foo') { define 'bar' }
    project('foo:bar').send(@task_name).name.should eql("foo:bar:#{@task_name}")
  end
end


describe Project, '#compile' do
  before { @task_name = 'compile' }
  it_should_behave_like 'accessor task'

  it 'should return a compile task' do
    define('foo').compile.should be_instance_of(CompileTask)
  end

  it 'should accept sources and add to source list' do
    define('foo') { compile('file1', 'file2') }
    project('foo').compile.sources.should include('file1', 'file2')
  end

  it 'should accept block and enhance task' do
    write 'src/main/java/Test.java', 'class Test {}'
    action = task('action')
    define('foo') { compile { action.invoke } }
    lambda { project('foo').compile.invoke }.should run_tasks('foo:compile', action)
  end

  it 'should execute resources task' do
    define 'foo'
    lambda { project('foo').compile.invoke }.should run_task('foo:resources')
  end

  it 'should be recursive' do
    write 'bar/src/main/java/Test.java', 'class Test {}'
    define('foo') { define 'bar' }
    lambda { project('foo').compile.invoke }.should run_task('foo:bar:compile')
  end

  it 'sould be a local task' do
    write 'bar/src/main/java/Test.java', 'class Test {}'
    define('foo') { define 'bar' }
    lambda do
      in_original_dir project('foo:bar').base_dir do
        task('compile').invoke
      end
    end.should run_task('foo:bar:compile').but_not('foo:compile')
  end

  it 'should run from build task' do
    write 'bar/src/main/java/Test.java', 'class Test {}'
    define('foo') { define 'bar' }
    lambda { task('build').invoke }.should run_task('foo:bar:compile')
  end

  it 'should clean after itself' do
    mkpath 'code'
    define('foo') { compile.into('code') }
    lambda { task('clean').invoke }.should change { File.exist?('code') }.to(false)
  end
end


describe Project, '#resources' do
  before { @task_name = 'resources' }
  it_should_behave_like 'accessor task'

  it 'should return a resources task' do
    define('foo').resources.should be_instance_of(ResourcesTask)
  end

  it 'should provide a filter' do
    define('foo').resources.filter.should be_instance_of(Filter)
  end

  it 'should include src/main/resources as source directory' do
    write 'src/main/resources/test'
    define('foo').resources.sources.first.should point_to_path('src/main/resources')
  end

  it 'should accept prerequisites' do
    tasks = ['task1', 'task2'].each { |name| task(name) }
    define('foo') { resources 'task1', 'task2' }
    lambda { project('foo').resources.invoke }.should run_tasks('task1', 'task2')
  end

  it 'should respond to from and add additional sources' do
    write 'src/main/resources/original'
    write 'extra/spicy'
    define('foo') { resources.from 'extra' }
    project('foo').resources.invoke
    FileList['target/resources/*'].sort.should  == ['target/resources/original', 'target/resources/spicy']
  end

  it 'should pass include pattern to filter' do
    3.times { |i| write "src/main/resources/test#{i + 1}" }
    define('foo') { resources.include('test2') }
    project('foo').resources.invoke
    FileList['target/resources/*'].should  == ['target/resources/test2']
  end

  it 'should pass exclude pattern to filter' do
    3.times { |i| write "src/main/resources/test#{i + 1}" }
    define('foo') { resources.exclude('test2') }
    project('foo').resources.invoke
    FileList['target/resources/*'].sort.should  == ['target/resources/test1', 'target/resources/test3']
  end

  it 'should accept block and enhance task' do
    action = task('action')
    define('foo') { resources { action.invoke } }
    lambda { project('foo').resources.invoke }.should run_tasks('foo:resources', action)
  end

  it 'should set target directory to target/resources' do
    define('foo').resources.target.to_s.should point_to_path('target/resources')
  end

  it 'should use provided target directoy' do
    define('foo') { resources.filter.into('the_resources') }
    project('foo').resources.target.to_s.should point_to_path('the_resources')
  end

  it 'should create file task for target directory' do
    define('foo').resources.should_receive(:execute)
    project('foo').file('target/resources').invoke
  end

  it 'should not be recursive' do
    define('foo') { define 'bar' }
    lambda { project('foo').resources.invoke }.should_not run_task('foo:bar:resources')
  end

  it 'should use current profile for filtering'
end


describe Project, '#javadoc' do
  before { @task_name = 'javadoc' }
  it_should_behave_like 'accessor task'

  def sources
    @sources ||= (1..3).map { |i| "Test#{i}" }.
      each { |name| write "src/main/java/foo/#{name}.java", "package foo; public class #{name}{}" }.
      map { |name| "src/main/java/foo/#{name}.java" }
  end

  it 'should set target directory to target/javadoc' do
    define('foo').javadoc.target.to_s.should point_to_path('target/javadoc')
  end

  it 'should create file task for target directory' do
    define('foo')
    project('foo').javadoc.should_receive(:invoke_prerequisites)
    project('foo').file('target/javadoc').invoke
  end

  it 'should respond to into() and return self' do
    task = nil
    define('foo') { task = javadoc.into('docs') }
    task.should be(project('foo').javadoc)
  end

  it 'should respond to info() and change target directory' do
    define('foo') { javadoc.into('docs') }
    project('foo').javadoc.should_receive(:invoke_prerequisites)
    file('docs').invoke
  end

  it 'should respond to from() and return self' do
    task = nil
    define('foo') { task = javadoc.from('srcs') }
    task.should be(project('foo').javadoc)
  end

  it 'should respond to from() and add sources' do
    define('foo') { javadoc.from 'srcs' }
    project('foo').javadoc.source_files.should include('srcs')
  end

  it 'should respond to from() and add file task' do
    define('foo') { javadoc.from file('srcs') }
    project('foo').javadoc.source_files.first.should point_to_path('srcs')
  end

  it 'should respond to from() and add project\'s sources and dependencies' do
    write 'bar/src/main/java/Test.java'
    define 'foo' do
      define('bar') { compile.with 'group:id:jar:1.0' }
      javadoc.from project('foo:bar')
    end
    project('foo').javadoc.source_files.first.should point_to_path('bar/src/main/java/Test.java')
    project('foo').javadoc.classpath.map(&:to_spec).should include('group:id:jar:1.0')
  end

  it 'should generate javadocs from project' do
    sources
    define 'foo'
    project('foo').javadoc.source_files.sort.should == sources.sort.map { |f| File.expand_path(f) }
  end

  it 'should include compile dependencies' do
    define('foo') { compile.with 'group:id:jar:1.0' }
    project('foo').javadoc.classpath.map(&:to_spec).should include('group:id:jar:1.0')
  end

  it 'should respond to include() and return self' do
    define('foo') { javadoc.include('srcs').should be(javadoc) }
  end

  it 'should respond to include() and add files' do
    define('foo').javadoc.include sources.first
    project('foo').javadoc.source_files.sort.should == [sources.first]
  end

  it 'should respond to exclude() and return self' do
    define('foo') { javadoc.exclude('srcs').should be(javadoc) }
  end

  it 'should respond to exclude() and ignore files' do
    sources
    define('foo').javadoc.exclude sources.first
    project('foo').javadoc.source_files.sort.should == sources[1..-1].map { |f| File.expand_path(f) }
  end

  it 'should respond to using() and return self' do
    define('foo') { javadoc.using(:windowtitle=>'Fooing').should be(javadoc) }
  end

  it 'should respond to using() and accept options' do
    define('foo') { javadoc.using :windowtitle=>'Fooing' }
    project('foo').javadoc.options[:windowtitle].should eql('Fooing')
  end

  it 'should pick -windowtitle from project name' do
    define('foo') { define 'bar' }
    project('foo').javadoc.options[:windowtitle].should eql('foo')
    project('foo:bar').javadoc.options[:windowtitle].should eql('foo:bar')
  end

  it 'should pick -windowtitle from project description' do
    desc 'My App'
    define('foo').javadoc.options[:windowtitle].should eql('My App')
  end

  it 'should produce documentation' do
    sources
    define('foo').javadoc.invoke
    (1..3).map { |i| "target/javadoc/foo/Test#{i}.html" }.each { |f| file(f).should exist }
  end

  it 'should fail on error' do
    write 'Test.java', 'class Test {}'
    define('foo') { javadoc.include 'Test.java' }
    lambda { project('foo').javadoc.invoke }.should raise_error(RuntimeError, /Failed to generate Javadocs/)
  end

  it 'should be local task' do
    define('foo') { define('bar') }
    project('foo:bar').javadoc.should_receive(:invoke_prerequisites)
    in_original_dir(project('foo:bar').base_dir) { task('javadoc').invoke }
  end

  it 'should not recurse' do
    define('foo') { define 'bar' }
    project('foo:bar').javadoc.should_not_receive(:invoke_prerequisites)
    project('foo').javadoc.invoke
  end
end
