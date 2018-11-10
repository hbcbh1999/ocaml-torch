open! Base

type t =
  { apply : Tensor.t -> Tensor.t
  }

type t_with_training =
  { apply_with_training : Tensor.t -> is_training:bool -> Tensor.t
  }

let set_training t_with_training ~is_training =
  let apply xs = t_with_training.apply_with_training xs ~is_training in
  { apply }

type activation =
  | Relu
  | Softmax
  | Log_softmax
  | Tanh
  | Leaky_relu
  | Sigmoid

let kaiming_uniform vs ~name ~shape ~a =
  let fan_in =
    match shape with
    | [] | [_] -> failwith "unexpected tensor shape"
    | _fan_out :: fan_in :: others ->
      let others = List.fold others ~init:1 ~f:( * ) in
      fan_in * others
  in
  let std = Float.sqrt (2. /. ((1. +. a *. a) *. Float.of_int fan_in)) in
  let bound = Float.sqrt 3. *. std in
  Var_store.new_var vs ~shape ~init:(Uniform (-. bound, bound)) ~name

let apply ?activation ys =
  match activation with
  | Some Relu -> Tensor.relu ys
  | Some Softmax -> Tensor.softmax ys
  | Some Log_softmax -> Tensor.log_softmax ys ~dim:(-1)
  | Some Tanh -> Tensor.tanh ys
  | Some Sigmoid -> Tensor.sigmoid ys
  | Some Leaky_relu -> Tensor.leaky_relu ys
  | None -> ys

let linear ?n vs ?activation ?(use_bias=true) ~input_dim output_dim =
  let name = Var_store.default_name vs n "linear" in
  let w =
    kaiming_uniform vs ~shape:[ output_dim; input_dim ] ~a:(Float.sqrt 5.)
      ~name:N.(name / "weight")
  in
  let apply =
    if use_bias
    then begin
      let bound = 1.0 /. Float.sqrt (Float.of_int input_dim) in
      let b =
        Var_store.new_var vs ~shape:[ output_dim ] ~init:(Uniform (-. bound, bound))
          ~name:N.(name / "bias")
      in
      fun xs -> Tensor.(mm xs (tr w) + b) |> apply ?activation
    end else fun xs -> Tensor.(mm xs (tr w)) |> apply ?activation
  in
  { apply }

let conv2d
      ?n
      vs
      ~ksize:(k1, k2)
      ~stride
      ?activation
      ?(use_bias=true)
      ?(padding=0, 0)
      ~input_dim
      output_dim
  =
  let name = Var_store.default_name vs n "conv2d" in
  let w =
    kaiming_uniform vs
      ~shape:[ output_dim; input_dim; k1; k2 ] ~a:(Float.sqrt 5.)
      ~name:N.(name / "weight")
  in
  let apply =
    if use_bias
    then begin
      let b =
        Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros
          ~name:N.(name / "bias")
      in
      fun xs -> Tensor.conv2d xs w b ~padding ~stride |> apply ?activation
    end else
      let b = Tensor.zeros [ output_dim ] ~device:(Var_store.device vs) in
      fun xs -> Tensor.conv2d xs w b ~padding ~stride |> apply ?activation
  in
  { apply }

let conv2d_ ?n vs ~ksize ~stride ?activation ?use_bias ?(padding = 0) ~input_dim output_dim =
  conv2d vs
    ?n
    ~ksize:(ksize, ksize)
    ~stride:(stride, stride)
    ?use_bias
    ?activation
    ~padding:(padding, padding)
    ~input_dim
    output_dim

let conv_transpose2d ?n vs ~ksize:(k1, k2) ~stride ?activation ?(padding=0, 0) ?(output_padding=0, 0) ~input_dim output_dim =
  let name = Var_store.default_name vs n "conv_transpose2d" in
  let w =
    Var_store.new_var vs
      ~shape:[ input_dim; output_dim; k1; k2 ] ~init:(Normal_with_stdev 0.1)
      ~name:N.(name / "weight")
  in
  let b =
    Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros
      ~name:N.(name / "bias")
  in
  let apply xs =
    Tensor.conv_transpose2d xs w b ~output_padding ~padding ~stride |> apply ?activation
  in
  { apply }

let conv_transpose2d_ ?n vs ~ksize ~stride ?activation ?(padding = 0) ?(output_padding = 0) ~input_dim output_dim =
  conv_transpose2d vs
    ?n
    ~ksize:(ksize, ksize)
    ~stride:(stride, stride)
    ?activation
    ~padding:(padding, padding)
    ~output_padding:(output_padding, output_padding)
    ~input_dim
    output_dim

let batch_norm2d ?n vs ?(eps=1e-5) ?(momentum=0.1) output_dim =
  let name = Var_store.default_name vs n "batch_norm2d" in
  let w =
    Var_store.new_var vs ~shape:[ output_dim ] ~init:(Uniform (0., 1.))
      ~name:N.(name / "weight")
  in
  let b =
    Var_store.new_var vs ~shape:[ output_dim ] ~init:Zeros
      ~name:N.(name / "bias")
  in
  let running_mean =
    Var_store.new_var vs ~trainable:false ~shape:[ output_dim ] ~init:Zeros
      ~name:N.(name / "running_mean")
  in
  let running_var =
    Var_store.new_var vs ~trainable:false ~shape:[ output_dim ] ~init:Ones
      ~name:N.(name / "running_var")
  in
  let apply_with_training xs ~is_training =
    Tensor.batch_norm xs
      ~weight:(Some w)
      ~bias:(Some b)
      ~running_mean:(Some running_mean)
      ~running_var:(Some running_var)
      ~training:is_training
      ~momentum
      ~eps
      ~cudnn_enabled:false
  in
  { apply_with_training }

let apply t xs = t.apply xs
let apply_ t_with_training xs ~is_training =
  t_with_training.apply_with_training xs ~is_training

let id = { apply = Fn.id }
let id_ = { apply_with_training = fun xs ~is_training:_ -> xs }
let of_fn apply = { apply }
let of_fn_ apply_with_training = { apply_with_training }

let fold t_list =
  let apply xs =
    List.fold t_list ~init:xs ~f:(fun acc t -> t.apply acc)
  in
  { apply }

let fold_ t_list =
  let apply_with_training xs ~is_training =
    List.fold t_list ~init:xs ~f:(fun acc t -> t.apply_with_training acc ~is_training)
  in
  { apply_with_training }

module Lstm = struct
  type t =
    { w_ih : Tensor.t
    ; w_hh : Tensor.t
    ; b_ih : Tensor.t
    ; b_hh : Tensor.t
    ; hidden_size : int
    ; device : Torch_core.Device.t
    }

  type state = Tensor.t * Tensor.t

  let create ?n vs ~input_dim ~hidden_size =
    let name = Var_store.default_name vs n "lstm" in
    let gate_size = 4 * hidden_size in
    let w_ih =
      kaiming_uniform vs ~shape:[ gate_size; input_dim ] ~a:(Float.sqrt 5.)
        ~name:N.(name / "w_ih")
    in
    let w_hh =
      kaiming_uniform vs ~shape:[ gate_size; hidden_size ] ~a:(Float.sqrt 5.)
        ~name:N.(name / "w_hh")
    in
    let b_ih =
      Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros
        ~name:N.(name / "b_ih")
    in
    let b_hh =
      Var_store.new_var vs ~shape:[ gate_size ] ~init:Zeros
        ~name:N.(name / "b_hh")
    in
    { w_ih; w_hh; b_ih; b_hh; hidden_size; device = Var_store.device vs }

  let zero_state t ~batch_size =
    let zeros = Tensor.zeros [ batch_size; t.hidden_size ] ~device:t.device in
    zeros, zeros

  let step t (h, c) input_ =
    Tensor.lstm_cell input_
      ~hx:[ h; c ] ~w_ih:t.w_ih ~w_hh:t.w_hh ~b_ih:(Some t.b_ih) ~b_hh:(Some t.b_hh)

  let seq t input_ =
    let batch_size = Tensor.shape input_ |> List.hd_exn in
    let h = Tensor.zeros [ 1; batch_size; t.hidden_size ] ~device:t.device in
    let c = Tensor.zeros [ 1; batch_size; t.hidden_size ] ~device:t.device in
    let output, h, c =
      Tensor.lstm1 input_
        ~hx:[ h; c ]
        ~params:[ t.w_ih; t.w_hh; t.b_ih; t.b_hh ]
        ~has_biases:true
        ~num_layers:1
        ~dropout:0.
        ~train:false
        ~bidirectional:false
        ~batch_first:true
    in
    output, (h, c)
end
