import Foundation
import NIOCore
import NIOPosix
#if !GUARDED_PIPE
func makeGuestPipeChannel(input: Int32, output: Int32, group: EventLoopGroup,
    initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>) -> EventLoopFuture<Channel> {
    NIOPipeBootstrap(group: group).channelInitializer(initialize)
        .takingOwnershipOfDescriptors(input: input, output: output).flatMapError { error in
            return group.next().submit { close(input); close(output); throw error }
        }
}
#endif
func require(_ b:Bool,_ s:String){if !b{fatalError(s)}}
enum Failure:Error{case injected}
let mode=CommandLine.arguments.last!
let group=MultiThreadedEventLoopGroup(numberOfThreads:1)
var a:[Int32]=[0,0],b:[Int32]=[0,0];require(pipe(&a)==0 && pipe(&b)==0,"pipe")
let input=a[0], output=b[1]
let retained=UnsafeMutablePointer<Int32>.allocate(capacity:2);retained.initialize(repeating:-1,count:2)
// Run the initializer's failed future through one event-loop callback after
// NIO closes its channel, before the bootstrap's failure reaches our caller.
final class ReuseAfterClose: ChannelInboundHandler, @unchecked Sendable {
 typealias InboundIn=ByteBuffer
 let fds:UnsafeMutablePointer<Int32>
 let input:Int32,output:Int32
 init(_ fds:UnsafeMutablePointer<Int32>,_ input:Int32,_ output:Int32){self.fds=fds;self.input=input;self.output=output}
 func handlerRemoved(context:ChannelHandlerContext){
  let first=open("/dev/null",O_RDONLY),second=open("/dev/null",O_RDONLY)
  require(first>=0 && second>=0,"replacement open")
  let x=dup(first),y=dup(second);close(first);close(second)
  require(dup2(x,input)==input && dup2(y,output)==output,"reuse")
  close(x);close(y);fds[0]=input;fds[1]=output
 }
}
if mode=="early" {close(input);a[0]=open(CommandLine.arguments[0],O_RDONLY);require(a[0]==input,"fixture fd reuse")}
let reused=ReuseAfterClose(retained,input,output)
let future=makeGuestPipeChannel(input:input,output:output,group:group){ channel in
 if mode=="early"{fatalError("regular file reached initializer")}
 return channel.pipeline.addHandler(reused).flatMap {
  return channel.eventLoop.makeFailedFuture(Failure.injected)
 }
}
do{_ = try future.wait();fatalError("failure expected")}catch{}
try group.next().submit{}.wait()
if mode=="early" {
 require(fcntl(input,F_GETFD) == -1 && fcntl(output,F_GETFD) == -1,"early failure leaked descriptors")
}else{
 require(retained[0]==input && retained[1]==output,"failure did not close channel")
 require(fcntl(input,F_GETFD)>=0 && fcntl(output,F_GETFD)>=0,"bootstrap failure closed reused descriptors")
 close(input);close(output)
}
close(a[1]);close(b[0]);retained.deinitialize(count:2);retained.deallocate()
try group.syncShutdownGracefully();print("pipe ownership passed \(mode)")
