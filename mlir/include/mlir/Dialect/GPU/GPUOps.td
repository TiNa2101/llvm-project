//===-- GPUOps.td - GPU dialect operation definitions ------*- tablegen -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Defines some operations of the GPU dialect.
//
//===----------------------------------------------------------------------===//

#ifndef GPU_OPS
#define GPU_OPS

include "mlir/Dialect/DLTI/DLTIBase.td"
include "mlir/Dialect/GPU/GPUBase.td"
include "mlir/Dialect/LLVMIR/LLVMOpBase.td"
include "mlir/IR/SymbolInterfaces.td"
include "mlir/Interfaces/DataLayoutInterfaces.td"
include "mlir/Interfaces/SideEffectInterfaces.td"

//===----------------------------------------------------------------------===//
// GPU Dialect operations.
//===----------------------------------------------------------------------===//

class GPU_Op<string mnemonic, list<OpTrait> traits = []> :
    Op<GPU_Dialect, mnemonic, traits>;

class GPU_IndexOp<string mnemonic, list<OpTrait> traits = []> :
    GPU_Op<mnemonic, !listconcat(traits, [NoSideEffect])>,
    Arguments<(ins StrAttr:$dimension)>, Results<(outs Index)> {
  let verifier = [{ return ::verifyIndexOp(*this); }];
}

def GPU_BlockDimOp : GPU_IndexOp<"block_dim"> {
  let description = [{
    Returns the number of threads in the thread block (aka the block size) along
    the x, y, or z `dimension`.

    Example:

    ```mlir
    %bDimX = "gpu.block_dim"() {dimension = "x"} : () -> (index)
    ```
  }];
}
def GPU_BlockIdOp : GPU_IndexOp<"block_id"> {
  let description = [{
    Returns the block id, i.e. the index of the current block within the grid
    along the x, y, or z `dimension`.

    Example:

    ```mlir
    %bIdY = "gpu.block_id"() {dimension = "y"} : () -> (index)
    ```
  }];
}
def GPU_GridDimOp : GPU_IndexOp<"grid_dim"> {
  let description = [{
    Returns the number of thread blocks in the grid along the x, y, or z
    `dimension`.

    Example:

    ```mlir
    %gDimZ = "gpu.grid_dim"() {dimension = "z"} : () -> (index)
    ```
  }];
}
def GPU_ThreadIdOp : GPU_IndexOp<"thread_id"> {
  let description = [{
    Returns the thread id, i.e. the index of the current thread within the block
    along the x, y, or z `dimension`.

    Example:

    ```mlir
    %tIdX = "gpu.thread_id"() {dimension = "x"} : () -> (index)
    ```
  }];
}

def GPU_SubgroupIdOp : GPU_Op<"subgroup_id", [NoSideEffect]>,
    Arguments<(ins)>, Results<(outs Index:$result)> {
  let description = [{
    Returns the subgroup id, i.e. the index of the current subgroup within the
    workgroup.

    Example:

    ```mlir
    %sgId = gpu.subgroup_id : index
    ```
  }];

  let assemblyFormat = "attr-dict `:` type($result)";
  let verifier = [{ return success(); }];
}

def GPU_NumSubgroupsOp : GPU_Op<"num_subgroups", [NoSideEffect]>,
    Arguments<(ins)>, Results<(outs Index:$result)> {
  let description = [{
    Returns the number of subgroups within a workgroup.

    Example:

    ```mlir
    %numSg = gpu.num_subgroups : index
    ```
  }];

  let assemblyFormat = "attr-dict `:` type($result)";
  let verifier = [{ return success(); }];
}

def GPU_SubgroupSizeOp : GPU_Op<"subgroup_size", [NoSideEffect]>,
    Arguments<(ins)>, Results<(outs Index:$result)> {
  let description = [{
    Returns the number of threads within a subgroup.

    Example:

    ```mlir
    %sgSz = gpu.subgroup_size : index
    ```
  }];

  let assemblyFormat = "attr-dict `:` type($result)";
  let verifier = [{ return success(); }];
}

def GPU_GPUFuncOp : GPU_Op<"func", [HasParent<"GPUModuleOp">,
                                    AutomaticAllocationScope, FunctionLike,
                                    IsolatedFromAbove, Symbol]> {
  let summary = "Function executable on a GPU";

  let description = [{
    Defines a function that can be executed on a GPU. This supports memory
    attribution and its body has a particular execution model.

    GPU functions are either kernels (as indicated by the `kernel` attribute) or
    regular functions. The former can be launched from the host side, while the
    latter are device side only.

    The memory attribution defines SSA values that correspond to memory buffers
    allocated in the memory hierarchy of the GPU (see below).

    The operation has one attached region that corresponds to the body of the
    function. The region arguments consist of the function arguments without
    modification, followed by buffers defined in memory annotations. The body of
    a GPU function, when launched, is executed by multiple work items. There are
    no guarantees on the order in which work items execute, or on the connection
    between them. In particular, work items are not necessarily executed in
    lock-step. Synchronization ops such as "gpu.barrier" should be used to
    coordinate work items. Declarations of GPU functions, i.e. not having the
    body region, are not supported.

    Syntax:

    ```
    op ::= `gpu.func` symbol-ref-id `(` argument-list `)` (`->`
    function-result-list)?
           memory-attribution `kernel`? function-attributes? region

    memory-attribution ::= (`workgroup` `(` ssa-id-and-type-list `)`)?
                           (`private` `(` ssa-id-and-type-list `)`)?
    ```

    Example:

    ```mlir
    gpu.func @foo(%arg0: index)
        workgroup(%workgroup: memref<32xf32, 3>)
        private(%private: memref<1xf32, 5>)
        kernel
        attributes {qux: "quux"} {
      gpu.return
    }
    ```

    The generic form illustrates the concept

    ```mlir
    "gpu.func"(%arg: index) {sym_name: "foo", kernel, qux: "quux"} ({
    ^bb0(%arg0: index, %workgroup: memref<32xf32, 3>,
         %private: memref<1xf32, 5>):
      "gpu.return"() : () -> ()
    }) : (index) -> ()
    ```

    Note the non-default memory spaces used in memref types in memory
    attribution.
  }];

  let regions = (region AnyRegion:$body);

  let skipDefaultBuilders = 1;

  let builders = [
    OpBuilder<(ins "StringRef":$name, "FunctionType":$type,
      CArg<"TypeRange", "{}">:$workgroupAttributions,
      CArg<"TypeRange", "{}">:$privateAttributions,
      CArg<"ArrayRef<NamedAttribute>", "{}">:$attrs)>
  ];

  let extraClassDeclaration = [{
    /// Returns `true` if the GPU function defined by this Op is a kernel, i.e.
    /// it is intended to be launched from host.
    bool isKernel() {
      return (*this)->getAttrOfType<UnitAttr>(
          GPUDialect::getKernelFuncAttrName()) != nullptr;
    }

    /// Returns the number of buffers located in the workgroup memory.
    unsigned getNumWorkgroupAttributions() {
      return (*this)->getAttrOfType<IntegerAttr>(
          getNumWorkgroupAttributionsAttrName()).getInt();
    }

    /// Returns a list of block arguments that correspond to buffers located in
    /// the workgroup memory
    ArrayRef<BlockArgument> getWorkgroupAttributions() {
      auto begin =
          std::next(getBody().args_begin(), getType().getNumInputs());
      auto end = std::next(begin, getNumWorkgroupAttributions());
      return {begin, end};
    }

    /// Adds a new block argument that corresponds to buffers located in
    /// workgroup memory.
    BlockArgument addWorkgroupAttribution(Type type);

    /// Returns the number of buffers located in the private memory.
    unsigned getNumPrivateAttributions() {
      return getBody().getNumArguments() - getType().getNumInputs() -
          getNumWorkgroupAttributions();
    }

    /// Returns a list of block arguments that correspond to buffers located in
    /// the private memory.
    ArrayRef<BlockArgument> getPrivateAttributions() {
      // Buffers on the private memory always come after buffers on the workgroup
      // memory.
      auto begin =
          std::next(getBody().args_begin(),
                    getType().getNumInputs() + getNumWorkgroupAttributions());
      return {begin, getBody().args_end()};
    }

    /// Adds a new block argument that corresponds to buffers located in
    /// private memory.
    BlockArgument addPrivateAttribution(Type type);

    /// Returns the name of the attribute containing the number of buffers
    /// located in the workgroup memory.
    static StringRef getNumWorkgroupAttributionsAttrName() {
      return "workgroup_attributions";
    }

    // FunctionLike trait needs access to the functions below.
    friend class OpTrait::FunctionLike<GPUFuncOp>;

    /// Hooks for the input/output type enumeration in FunctionLike .
    unsigned getNumFuncArguments() { return getType().getNumInputs(); }
    unsigned getNumFuncResults() { return getType().getNumResults(); }

    /// Returns the keywords used in the custom syntax for this Op.
    static StringRef getWorkgroupKeyword() { return "workgroup"; }
    static StringRef getPrivateKeyword() { return "private"; }
    static StringRef getKernelKeyword() { return "kernel"; }

    /// Hook for FunctionLike verifier.
    LogicalResult verifyType();

    /// Verifies the body of the function.
    LogicalResult verifyBody();
  }];

  // let verifier = [{ return ::verifFuncOpy(*this); }];
  let printer = [{ printGPUFuncOp(p, *this); }];
  let parser = [{ return parseGPUFuncOp(parser, result); }];
}

def GPU_LaunchFuncOp : GPU_Op<"launch_func",
                              [GPU_AsyncOpInterface, AttrSizedOperandSegments]>,
    Arguments<(ins Variadic<GPU_AsyncToken>:$asyncDependencies,
               SymbolRefAttr:$kernel,
               Index:$gridSizeX, Index:$gridSizeY, Index:$gridSizeZ,
               Index:$blockSizeX, Index:$blockSizeY, Index:$blockSizeZ,
               Variadic<AnyType>:$operands)>,
    Results<(outs Optional<GPU_AsyncToken>:$asyncToken)> {
  let summary = "Launches a function as a GPU kernel";

  let description = [{
    Launch a kernel function on the specified grid of thread blocks.
    `gpu.launch` operations are lowered to `gpu.launch_func` operations by
    outlining the kernel body into a function in a dedicated module, which
    reflects the separate compilation process. The kernel function is required
    to have the `gpu.kernel` attribute. The module containing the kernel
    function is required to be a gpu.module. And finally, the module containing
    the kernel module (which thus cannot be the top-level module) is required
    to have the `gpu.container_module` attribute. The `gpu.launch_func`
    operation has a symbol attribute named `kernel` to identify the fully
    specified kernel function to launch (both the gpu.module and func).

    The `gpu.launch_func` supports async dependencies: the kernel does not start
    executing until the ops producing those async dependencies have completed.

    By the default, the host implicitly blocks until kernel execution has
    completed. If the `async` keyword is present, the host does not block but
    instead a `!gpu.async.token` is returned. Other async GPU ops can take this
    token as dependency.

    The operation requires at least the grid and block sizes along the x,y,z
    dimensions as arguments. When a lower-dimensional kernel is required,
    unused sizes must be explicitly set to `1`.

    The remaining operands are passed as arguments to the kernel function.

    Example:

    ```mlir
    module attributes {gpu.container_module} {

      // This module creates a separate compilation unit for the GPU compiler.
      gpu.module @kernels {
        func @kernel_1(%arg0 : f32, %arg1 : memref<?xf32, 1>)
            attributes { nvvm.kernel = true } {

          // Operations that produce block/thread IDs and dimensions are
          // injected when outlining the `gpu.launch` body to a function called
          // by `gpu.launch_func`.
          %tIdX = "gpu.thread_id"() {dimension = "x"} : () -> (index)
          %tIdY = "gpu.thread_id"() {dimension = "y"} : () -> (index)
          %tIdZ = "gpu.thread_id"() {dimension = "z"} : () -> (index)

          %bDimX = "gpu.block_dim"() {dimension = "x"} : () -> (index)
          %bDimY = "gpu.block_dim"() {dimension = "y"} : () -> (index)
          %bDimZ = "gpu.block_dim"() {dimension = "z"} : () -> (index)

          %bIdX = "gpu.block_id"() {dimension = "x"} : () -> (index)
          %bIdY = "gpu.block_id"() {dimension = "y"} : () -> (index)
          %bIdZ = "gpu.block_id"() {dimension = "z"} : () -> (index)

          %gDimX = "gpu.grid_dim"() {dimension = "x"} : () -> (index)
          %gDimY = "gpu.grid_dim"() {dimension = "y"} : () -> (index)
          %gDimZ = "gpu.grid_dim"() {dimension = "z"} : () -> (index)

          "some_op"(%bx, %tx) : (index, index) -> ()
          %42 = load %arg1[%bx] : memref<?xf32, 1>
        }
      }

      %t0 = gpu.wait async
      gpu.launch_func
          async                           // (Optional) Don't block host, return token.
          [%t0]                           // (Optional) Execute only after %t0 has completed.
          @kernels::@kernel_1             // Kernel function.
          blocks in (%cst, %cst, %cst)    // Grid size.
          threads in (%cst, %cst, %cst)   // Block size.
          args(%arg0 : f32,               // (Optional) Kernel arguments.
               %arg1 : memref<?xf32, 1>)
    }
    ```
  }];

  let skipDefaultBuilders = 1;

  let builders = [
    OpBuilder<(ins "GPUFuncOp":$kernelFunc, "KernelDim3":$gridSize,
      "KernelDim3":$blockSize, "ValueRange":$kernelOperands)>
  ];

  let extraClassDeclaration = [{
    /// The number of operands passed to the kernel function.
    unsigned getNumKernelOperands();

    /// The name of the kernel's containing module.
    StringAttr getKernelModuleName();

    /// The name of the kernel.
    StringAttr getKernelName();

    /// The i-th operand passed to the kernel function.
    Value getKernelOperand(unsigned i);

    /// Get the SSA values passed as operands to specify the grid size.
    KernelDim3 getGridSizeOperandValues();

    /// Get the SSA values passed as operands to specify the block size.
    KernelDim3 getBlockSizeOperandValues();

    /// The number of launch configuration operands, placed at the leading
    /// positions of the operand list.
    static constexpr unsigned kNumConfigOperands = 6;

    // This needs to quietly verify if attributes with names defined below are
    // present since it is run before the verifier of this op.
    friend LogicalResult GPUDialect::verifyOperationAttribute(Operation *,
                                                              NamedAttribute);

    /// The name of the symbol reference attribute specifying the kernel to launch.
    static StringRef getKernelAttrName() { return "kernel"; }
  }];

  let verifier = [{ return ::verify(*this); }];
  let assemblyFormat = [{
      custom<AsyncDependencies>(type($asyncToken), $asyncDependencies)
      $kernel
      `blocks` `in` ` ` `(`$gridSizeX`,` $gridSizeY`,` $gridSizeZ`)`
      `threads` `in` ` ` `(`$blockSizeX`,` $blockSizeY`,` $blockSizeZ`)`
      custom<LaunchFuncOperands>($operands, type($operands))
      attr-dict
  }];
}

def GPU_LaunchOp : GPU_Op<"launch">,
    Arguments<(ins Index:$gridSizeX, Index:$gridSizeY, Index:$gridSizeZ,
               Index:$blockSizeX, Index:$blockSizeY, Index:$blockSizeZ)>,
    Results<(outs)> {
  let summary = "GPU kernel launch operation";

  let description = [{
    Launch a kernel on the specified grid of thread blocks. The body of the
    kernel is defined by the single region that this operation contains. The
    operation takes six operands, with first three operands being grid sizes
    along x,y,z dimensions and the following three arguments being block sizes
    along x,y,z dimension. When a lower-dimensional kernel is required,
    unused sizes must be explicitly set to `1`.

    The body region has _twelve_ arguments, grouped as follows:

    -   three arguments that contain block identifiers along x,y,z dimensions;
    -   three arguments that contain thread identifiers along x,y,z dimensions;
    -   operands of the `gpu.launch` operation as is (i.e. the operands for
        grid and block sizes).

    Syntax:

    ```
    operation ::= `gpu.launch` `block` `(` ssa-id-list `)` `in` ssa-reassignment
                             `threads` `(` ssa-id-list `)` `in` ssa-reassignment
                               region attr-dict?
    ssa-reassignment ::= `(` ssa-id `=` ssa-use (`,` ssa-id `=` ssa-use)* `)`
    ```

    Example:

    ```mlir
    gpu.launch blocks(%bx, %by, %bz) in (%sz_bx = %0, %sz_by = %1, %sz_bz = %2)
               threads(%tx, %ty, %tz) in (%sz_tx = %3, %sz_ty = %4, %sz_tz = %5) {
      // Block and thread identifiers, as well as block/grid sizes are
      // immediately usable inside body region.
      "some_op"(%bx, %tx) : (index, index) -> ()
      // Assuming %val1 is defined outside the gpu.launch region.
      %42 = load %val1[%bx] : memref<?xf32, 1>
    }

    // Generic syntax explains how the pretty syntax maps to the IR structure.
    "gpu.launch"(%cst, %cst, %c1,  // Grid sizes.
                 %cst, %c1, %c1)   // Block sizes.

        {/*attributes*/}
        // All sizes and identifiers have "index" size.
        : (index, index, index, index, index, index) -> () {
    // The operation passes block and thread identifiers, followed by grid and
    // block sizes.
    ^bb0(%bx : index, %by : index, %bz : index,
         %tx : index, %ty : index, %tz : index,
         %num_bx : index, %num_by : index, %num_bz : index,
         %num_tx : index, %num_ty : index, %num_tz : index)
      "some_op"(%bx, %tx) : (index, index) -> ()
      %3 = "memref.load"(%val1, %bx) : (memref<?xf32, 1>, index) -> f32
    }
    ```

    Rationale: using operation/block arguments gives analyses a clear way of
    understanding that a value has additional semantics (e.g., we will need to
    know what value corresponds to threadIdx.x for coalescing). We can recover
    these properties by analyzing the operations producing values, but it is
    easier just to have that information by construction.
  }];

  let regions = (region AnyRegion:$body);

  let skipDefaultBuilders = 1;

  let builders = [
    OpBuilder<(ins "Value":$gridSizeX, "Value":$gridSizeY,
      "Value":$gridSizeZ, "Value":$blockSizeX, "Value":$blockSizeY,
      "Value":$blockSizeZ)>
  ];

  let extraClassDeclaration = [{
    /// Get the SSA values corresponding to kernel block identifiers.
    KernelDim3 getBlockIds();
    /// Get the SSA values corresponding to kernel thread identifiers.
    KernelDim3 getThreadIds();
    /// Get the SSA values corresponding to kernel grid size.
    KernelDim3 getGridSize();
    /// Get the SSA values corresponding to kernel block size.
    KernelDim3 getBlockSize();

    /// Get the SSA values passed as operands to specify the grid size.
    KernelDim3 getGridSizeOperandValues();
    /// Get the SSA values passed as operands to specify the block size.
    KernelDim3 getBlockSizeOperandValues();

    static StringRef getBlocksKeyword() { return "blocks"; }
    static StringRef getThreadsKeyword() { return "threads"; }

    /// The number of launch configuration operands, placed at the leading
    /// positions of the operand list.
    static constexpr unsigned kNumConfigOperands = 6;

    /// The number of region attributes containing the launch configuration,
    /// placed in the leading positions of the argument list.
    static constexpr unsigned kNumConfigRegionAttributes = 12;
  }];

  let parser = [{ return parseLaunchOp(parser, result); }];
  let printer = [{ printLaunchOp(p, *this); }];
  let verifier = [{ return ::verify(*this); }];
}

def GPU_ReturnOp : GPU_Op<"return", [HasParent<"GPUFuncOp">, NoSideEffect,
                                     Terminator]>,
    Arguments<(ins Variadic<AnyType>:$operands)>, Results<(outs)> {
  let summary = "Terminator for GPU functions.";
  let description = [{
    A terminator operation for regions that appear in the body of  `gpu.func`
    functions. The operands to the `gpu.return` are the result values returned
    by an invocation of the `gpu.func`.
  }];

  let builders = [OpBuilder<(ins), [{ // empty}]>];

  let parser = [{ return parseReturnOp(parser, result); }];
  let printer = [{ p << getOperationName(); }];
  let verifier = [{ return ::verify(*this); }];
}

def GPU_TerminatorOp : GPU_Op<"terminator", [HasParent<"LaunchOp">,
                                             NoSideEffect, Terminator]>,
    Arguments<(ins)>, Results<(outs)> {
  let summary = "Terminator for GPU launch regions.";
  let description = [{
    A terminator operation for regions that appear in the body of `gpu.launch`
    operation.  These regions are not expected to return any value so the
    terminator takes no operands.
  }];

  let parser = [{ return success(); }];
  let printer = [{ p << getOperationName(); }];
}

def GPU_YieldOp : GPU_Op<"yield", [NoSideEffect, Terminator]>,
    Arguments<(ins Variadic<AnyType>:$values)> {
  let summary = "GPU yield operation";
  let description = [{
    gpu.yield` is a special terminator operation for blocks inside regions
    in gpu ops. It returns values to the immediately enclosing gpu op.

    Example:

    ```mlir
    gpu.yield %f0, %f1 : f32, f32
    ```
  }];
}

// add, mul mirror the XLA ComparisonDirection enum.
def GPU_AllReduceOpAdd : StrEnumAttrCase<"add">;
def GPU_AllReduceOpAnd : StrEnumAttrCase<"and">;
def GPU_AllReduceOpMax : StrEnumAttrCase<"max">;
def GPU_AllReduceOpMin : StrEnumAttrCase<"min">;
def GPU_AllReduceOpMul : StrEnumAttrCase<"mul">;
def GPU_AllReduceOpOr : StrEnumAttrCase<"or">;
def GPU_AllReduceOpXor : StrEnumAttrCase<"xor">;

def GPU_AllReduceOperationAttr : StrEnumAttr<"AllReduceOperationAttr",
    "built-in reduction operations supported by gpu.allreduce.",
    [
      GPU_AllReduceOpAdd,
      GPU_AllReduceOpAnd,
      GPU_AllReduceOpMax,
      GPU_AllReduceOpMin,
      GPU_AllReduceOpMul,
      GPU_AllReduceOpOr,
      GPU_AllReduceOpXor
    ]>;

def GPU_AllReduceOp : GPU_Op<"all_reduce",
    [SameOperandsAndResultType, IsolatedFromAbove]>,
    Arguments<(ins AnyType:$value,
               OptionalAttr<GPU_AllReduceOperationAttr>:$op)>,
    Results<(outs AnyType)> {
  let summary = "Reduce values among workgroup.";
  let description = [{
    The `all_reduce` op reduces the value of every work item across a local
    workgroup. The result is equal for all work items of a workgroup.

    For example, both

    ```mlir
    %1 = "gpu.all_reduce"(%0) ({}) { op = "add" } : (f32) -> (f32)
    %2 = "gpu.all_reduce"(%0) ({
    ^bb(%lhs : f32, %rhs : f32):
      %sum = addf %lhs, %rhs : f32
      "gpu.yield"(%sum) : (f32) -> ()
    }) : (f32) -> (f32)
    ```

    compute the sum of each work item's %0 value. The first version specifies
    the accumulation as operation, whereas the second version specifies the
    accumulation as code region. The accumulation operation must be one of:
    `add`, `and`, `max`, `min`, `mul`, `or`, `xor`.

    Either none or all work items of a workgroup need to execute this op
    in convergence.
  }];
  let regions = (region AnyRegion:$body);
  let verifier = [{ return ::verifyAllReduce(*this); }];
}

def GPU_ShuffleOpXor : StrEnumAttrCase<"xor">;

def GPU_ShuffleModeAttr : StrEnumAttr<"ShuffleModeAttr",
    "Indexing modes supported by gpu.shuffle.",
    [
      GPU_ShuffleOpXor,
    ]>;

def GPU_ShuffleOp : GPU_Op<"shuffle", [NoSideEffect]>,
    Arguments<(ins AnyType:$value, I32:$offset, I32:$width,
               GPU_ShuffleModeAttr:$mode)>,
    Results<(outs AnyType:$result, I1:$valid)> {
  let summary = "Shuffles values within a subgroup.";
  let description = [{
    The "shuffle" op moves values to a different invocation within the same
    subgroup.

    Example:

    ```mlir
    %1, %2 = gpu.shuffle %0, %offset, %width xor : f32
    ```

    For lane k returns the value from lane `k ^ offset` and `true` if that lane
    is smaller than %width. Otherwise it returns an unspecified value and
    `false`. A lane is the index of an invocation relative to its subgroup.

    The width specifies the number of invocations that participate in the
    shuffle. The width needs to be the same for all invocations that participate
    in the shuffle. Exactly the first `width` invocations of a subgroup need to
    execute this op in convergence.
  }];
  let verifier = [{ return ::verifyShuffleOp(*this); }];
  let printer = [{ printShuffleOp(p, *this); }];
  let parser = [{ return parseShuffleOp(parser, result); }];
}

def GPU_BarrierOp : GPU_Op<"barrier"> {
  let summary = "Synchronizes all work items of a workgroup.";
  let description = [{
    The "barrier" op synchronizes all work items of a workgroup. It is used
    to coordinate communication between the work items of the workgroup.

    ```mlir
    gpu.barrier
    ```

    waits until all work items in the workgroup have reached this point
    and all memory accesses made by these work items prior to the op are
    visible to all work items in the workgroup. Data hazards between work items
    accessing the same memory can be avoided by synchronizing work items
    in-between these accesses.

    Either none or all work items of a workgroup need to execute this op
    in convergence.
  }];
  let parser = [{ return success(); }];
  let printer = [{ p << getOperationName(); }];
}

def GPU_GPUModuleOp : GPU_Op<"module", [
  DataLayoutOpInterface, HasDefaultDLTIDataLayout, IsolatedFromAbove,
  SymbolTable, Symbol,
  SingleBlockImplicitTerminator<"ModuleEndOp">
]> {
  let summary = "A top level compilation unit containing code to be run on a GPU.";
  let description = [{
    GPU module contains code that is intended to be run on a GPU. A host device
    can launch this code through a gpu.launc_func that creates a fully
    qualified symbol through the gpu.module's symbol and a gpu.func symbol
    contained in the gpu.module.

    The module's top-level scope is modeled by a single region with a single
    block. GPU modules are required to have a name that is used for symbol
    resolution by the gpu.launch_func operation.

    Using an op with a region to define a GPU module enables "embedding" GPU
    modules with SIMT execution models in other dialects in a clean manner and
    allows filtering of code regions to execute passes on only code intended to
    or not intended to be run on the separate device.

    ```
      gpu.module @symbol_name {
      gpu.func {}
        ...
      gpu.module_end
    }

    ```
  }];
  let builders = [OpBuilder<(ins "StringRef":$name)>];
  let parser = [{ return ::parseGPUModuleOp(parser, result); }];
  let printer = [{ return ::print(p, *this); }];
  let regions = (region SizedRegion<1>:$body);

  // We need to ensure the block inside the region is properly terminated;
  // the auto-generated builders do not guarantee that.
  let skipDefaultBuilders = 1;
}

def GPU_ModuleEndOp : GPU_Op<"module_end", [
  Terminator, HasParent<"GPUModuleOp">
]> {
  let summary = "A pseudo op that marks the end of a gpu.module.";
  let description = [{
    This op terminates the only block inside the only region of a `gpu.module`.
  }];

  let parser = [{ return success(); }];
  let printer = [{ p << getOperationName(); }];
}

def GPU_HostRegisterOp : GPU_Op<"host_register">,
    Arguments<(ins AnyUnrankedMemRef:$value)> {
  let summary = "Registers a memref for access from device.";
  let description = [{
    This op maps the provided host buffer into the device address space.

    This operation may not be supported in every environment, there is not yet a
    way to check at runtime whether this feature is supported.

    Writes from the host are guaranteed to be visible to device kernels that are
    launched afterwards. Writes from the device are guaranteed to be visible on
    the host after synchronizing with the device kernel completion.
  }];

  let assemblyFormat = "$value attr-dict `:` type($value)";
  let verifier = [{ return success(); }];
}

def GPU_WaitOp : GPU_Op<"wait", [GPU_AsyncOpInterface]> {
  let summary = "Wait for async gpu ops to complete.";
  let description = [{
    This op synchronizes the host or the device with a list of dependent ops.

    If the op contains the `async` keyword, it returns a new async token which
    is synchronized with the op arguments. This new token is merely a shortcut
    to the argument list, and one could replace the uses of the result with the
    arguments for the same effect. The async version of this op is primarily
    used to make each async token have a single use during lowering and
    thereby make forks in async execution explicit. Example usage:

    ```mlir
    %t0 = gpu.foo async : !gpu.async.token
    %t1 = gpu.bar async : !gpu.async.token
    %t2 = gpu.wait async [%t0, %t1]
    // gpu.baz doesn't run until gpu.foo and gpu.bar have both completed, just
    // as if the async dependencies were [%t0, %t1].
    %t3 = gpu.baz async [%t2]
    ```

    If the op does not contain the `async` keyword, it does not return a new
    async token but blocks until all ops producing the async dependency tokens
    finished execution. All dependent memory operations are visible to the host
    once this op completes. Example usage:

    ```mlir
    %t0 = gpu.foo async : !gpu.async.token
    %t1 = gpu.bar async : !gpu.async.token
    // The gpu.wait op blocks until gpu.foo and gpu.bar have completed.
    gpu.wait [%t0, %t1]
    ```
  }];

  let arguments = (ins Variadic<GPU_AsyncToken>:$asyncDependencies);
  let results = (outs Optional<GPU_AsyncToken>:$asyncToken);

  let assemblyFormat = [{
    custom<AsyncDependencies>(type($asyncToken), $asyncDependencies) attr-dict
  }];
}

def GPU_AllocOp : GPU_Op<"alloc", [
    GPU_AsyncOpInterface,
    AttrSizedOperandSegments
  ]> {

  let summary = "GPU memory allocation operation.";
  let description = [{
    The `gpu.alloc` operation allocates a region of memory on the GPU. It is
    similar to the `memref.alloc` op, but supports asynchronous GPU execution.

    The op does not execute before all async dependencies have finished
    executing.

    If the `async` keyword is present, the op is executed asynchronously (i.e.
    it does not block until the execution has finished on the device). In
    that case, it also returns a !gpu.async.token.

    Example:

    ```mlir
    %memref, %token = gpu.alloc async [%dep] (%width) : memref<64x?xf32, 1>
    ```
  }];

  let arguments = (ins Variadic<GPU_AsyncToken>:$asyncDependencies,
                   Variadic<Index>:$dynamicSizes, Variadic<Index>:$symbolOperands);
  let results = (outs Res<AnyMemRef, "", [MemAlloc]>:$memref,
                 Optional<GPU_AsyncToken>:$asyncToken);

  let extraClassDeclaration = [{
    MemRefType getType() { return memref().getType().cast<MemRefType>(); }
  }];

  let assemblyFormat = [{
    custom<AsyncDependencies>(type($asyncToken), $asyncDependencies) ` `
    `(` $dynamicSizes `)` (`` `[` $symbolOperands^ `]`)? attr-dict `:` type($memref)
  }];
}

def GPU_DeallocOp : GPU_Op<"dealloc", [GPU_AsyncOpInterface]> {

  let summary = "GPU memory deallocation operation";

  let description = [{
    The `gpu.dealloc` operation frees the region of memory referenced by a
    memref which was originally created by the `gpu.alloc` operation. It is
    similar to the `memref.dealloc` op, but supports asynchronous GPU execution.

    The op does not execute before all async dependencies have finished
    executing.

    If the `async` keyword is present, the op is executed asynchronously (i.e.
    it does not block until the execution has finished on the device). In
    that case, it returns a !gpu.async.token.

    Example:

    ```mlir
    %token = gpu.dealloc async [%dep] %memref : memref<8x64xf32, 1>
    ```
  }];

  let arguments = (ins Variadic<GPU_AsyncToken>:$asyncDependencies,
                   Arg<AnyMemRef, "", [MemFree]>:$memref);
  let results = (outs Optional<GPU_AsyncToken>:$asyncToken);

  let assemblyFormat = [{
    custom<AsyncDependencies>(type($asyncToken), $asyncDependencies)
    $memref attr-dict `:` type($memref)
  }];
}

def GPU_MemcpyOp : GPU_Op<"memcpy", [GPU_AsyncOpInterface]> {

  let summary = "GPU memcpy operation";

  let description = [{
    The `gpu.memcpy` operation copies the content of one memref to another.

    The op does not execute before all async dependencies have finished
    executing.

    If the `async` keyword is present, the op is executed asynchronously (i.e.
    it does not block until the execution has finished on the device). In
    that case, it returns a !gpu.async.token.

    Example:

    ```mlir
    %token = gpu.memcpy async [%dep] %dst, %src : memref<?xf32, 1>, memref<?xf32>
    ```
  }];

  let arguments = (ins Variadic<GPU_AsyncToken>:$asyncDependencies,
                   Arg<AnyMemRef, "", [MemWrite]>:$dst,
                   Arg<AnyMemRef, "", [MemRead]>:$src);
  let results = (outs Optional<GPU_AsyncToken>:$asyncToken);

  let assemblyFormat = [{
    custom<AsyncDependencies>(type($asyncToken), $asyncDependencies)
    $dst`,` $src `:` type($dst)`,` type($src) attr-dict
  }];
  let verifier = [{ return ::verify(*this); }];
  let hasFolder = 1;
}

def GPU_SubgroupMmaLoadMatrixOp : GPU_Op<"subgroup_mma_load_matrix",
    [MemoryEffects<[MemRead]>]>{

  let summary = "GPU warp synchronous matrix load";

  let description = [{
    The `gpu.subgroup_mma_load_matrix` operation loads a matrix collectively
    using all the threads in a subgroup.

    This operation takes a memref as its first operand: it is the source matrix
    from which data is to be loaded. The op returns a `!gpu.mma_matrix`. The
    source memref can be in global memory or shared memory. The load address is
    determined using `indices`. The matrix being loaded into is the result.  The
    `leadDimension` attribute specifies the leading dimension size of the source
    matrix which eventually allows the lowering to determine the size of each
    row.

    This op is often meant to be used along with `gpu.subgroup_mma_store_matrix` and
    `gpu.subgroup_mma_compute`.

    Example:

    ```mlir
     %0 = gpu.subgroup_mma_load_matrix src[%i,%j] : {leadDimension = 32 : i32}
          : memref<32x32xf16, 3>, !gpu.mma_matrix<16x16xf16, "AOp">
    ```
  }];

  let arguments = (ins Arg<MemRefRankOf<[F16, F32], [2]>, "", [MemRead]>:$srcMemref,
                  Variadic<Index>:$indices,
                  IndexAttr:$leadDimension);

  let results = (outs GPU_MMAMatrix:$res);

  let assemblyFormat = [{
    $srcMemref`[`$indices`]` attr-dict `:` type($srcMemref) `->` type($res)
  }];

  let verifier = [{ return ::verify(*this); }];
}

def GPU_SubgroupMmaStoreMatrixOp : GPU_Op<"subgroup_mma_store_matrix",
    [MemoryEffects<[MemWrite]>]>{

  let summary = "GPU warp synchronous matrix store";

  let description = [{
    The `gpu.subgroup_mma_store_matrix` operation stores a matrix collectively
    using all the threads in a subgroup.

    This operation takes a `!gpu.mma_matrix` and a memref as operands.
    `!gpu.mma_matrix` is the source value containing the data to be stored into the
    destination memref which can be in global or shared memory.  The store address
    is determined using the indices provided. The `leadDimension` attribute
    specifies the leading dimension of the destination matrix.

    This op is often meant to be used along with `gpu.subgroup_mma_load_matrix` and
    `gpu.subgroup_mma_compute`.

    Example:

    ```mlir
    gpu.subgroup_mma_store_matrix %D, %sg[%i,%j] : { leadDimension = 32 : i32}
                    : !gpu.mma_matrix<16x16xf16, "COp">, memref<32x32xf16, 3>
    ```
  }];

  let arguments = (ins Arg<MMAMatrixOf<[F16, F32]>>:$src,
                  Arg<MemRefRankOf<[F16, F32], [2]>, "",[MemWrite]>:$dstMemref,
                  Variadic<Index>:$indices,
                  IndexAttr:$leadDimension);

  let assemblyFormat = [{
    $src`,` $dstMemref`[`$indices`]` attr-dict `:` type($src)`,` type($dstMemref)
  }];

  let verifier = [{ return ::verify(*this); }];
}

def GPU_SubgroupMmaComputeOp : GPU_Op<"subgroup_mma_compute",
   [NoSideEffect, AllTypesMatch<["opC", "res"]>]>{

  let summary = "GPU warp synchronous matrix multiply accumulate";

  let description = [{
    The `gpu.subgroup_mma_compute` operation performs a matrix-multiply accumulate (mma)
    operation using all the threads in a subgroup.

    This operation takes three `!gpu.mma_matrix`s as arguments: these hold `A`,
     `B` and `C`operands for the mma operation. The operation performed is represented
    as `C += A * B`. The op returns a `!gpu.mma_matrix` which contains the result of
    the operation held by all threads in a subgroup.

    This op is meant to be used along with `gpu.subgroup_mma_store_matrix` and
    `gpu.subgroup_mma_load_matrix` ops.

    Example:

    ```mlir
    %D = gpu.subgroup_mma_compute_matrix %A, %B, %C :
      !gpu.mma_matrix<16x16xf16, "AOp">, !gpu.mma_matrix<16x16xf16, "BOp">>
      -> !gpu.mma_matrix<16x16xf16, "COp">
    ```
  }];

  let arguments = (ins Arg<MMAMatrixOf<[F16]>>:$opA,
                  Arg<MMAMatrixOf<[F16]>>:$opB,
                  Arg<MMAMatrixOf<[F16, F32]>>:$opC);

  let results = (outs GPU_MMAMatrix:$res);

  let assemblyFormat = [{
    $opA`,` $opB`,` $opC attr-dict `:` type($opA)`,` type($opB) `->` type($res)
  }];

  let verifier = [{ return ::verify(*this); }];
}

def GPU_SubgroupMmaConstantMatrixOp : GPU_Op<"subgroup_mma_constant_matrix",
    [NoSideEffect,
     TypesMatchWith<"value type matches element type of mma_matrix",
                    "res", "value",
                    "$_self.cast<gpu::MMAMatrixType>().getElementType()">]>{

  let summary = "GPU warp synchronous constant matrix";

  let description = [{
    The `gpu.subgroup_mma_constant_matrix` creates a `!gpu.mma_matrix` with
    constant elements.

    The operation takes a scalar input and return a `!gpu.mma_matrix` where each
    element of is equal to the operand constant. The destination mma_matrix type
    must have elememt type equal to the constant type. Since the layout of
    `!gpu.mma_matrix` is opaque this only support setting all the elements to
    the same value.

    This op is meant to be used along with `gpu.subgroup_mma_compute`.
    
    Example:

    ```mlir
     %0 = gpu.subgroup_mma_constant_matrix %a :
       !gpu.mma_matrix<16x16xf16, "AOp">
     %1 = gpu.subgroup_mma_constant_matrix %b :
       !gpu.mma_matrix<16x16xf32, "COp">
    ```
  }];

  let arguments = (ins AnyTypeOf<[F16, F32]>:$value);

  let results = (outs GPU_MMAMatrix:$res);

  let extraClassDeclaration = [{
    gpu::MMAMatrixType getType() {
      return res().getType().cast<gpu::MMAMatrixType>();
    }
  }];

  let assemblyFormat = [{
    $value attr-dict `:` type($res)
  }];
}

#endif // GPU_OPS
