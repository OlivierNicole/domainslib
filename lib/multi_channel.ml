
module Ws_deque = Ws_deque.M

type mutex_condvar = {
  mutex: Mutex.t;
  condition: Condition.t
}

let mc_key =
  Domain.DLS.new_key (fun () ->
    let m = Mutex.create () in
    let c = Condition.create () in
    {mutex=m; condition=c})

type waiting_released =
  | Waiting
  | Released

type 'a t = {
  mask: int;
  channels: 'a Ws_deque.t array;
  waiters: (waiting_released ref * mutex_condvar ) Chan.t;
  next_domain_id: int Atomic.t;
}

let id_key =
  Domain.DLS.new_key (fun () -> (-1))

let rec log2 n =
  if n <= 1 then 0 else 1 + (log2 (n asr 1))

let make n =
  let sz = Int.shift_left 1 (log2 n) in
  assert ((sz >= n) && (sz > 0));
  assert (Int.logand sz (sz-1) == 0);
  { mask = sz - 1;
    channels = Array.init sz (fun _ -> Ws_deque.create ());
    waiters = Chan.make_unbounded ();
    next_domain_id = Atomic.make 0
    }

let rec check_waiters mchan =
  match Chan.recv_poll mchan.waiters with
    | None -> ()
    | Some (status, mc) ->
      begin
        Mutex.lock mc.mutex;
        match !status with
        | Waiting ->
          begin
            status := Released;
            Mutex.unlock mc.mutex;
            Condition.broadcast mc.condition
          end
        | Released ->
          begin
            (* this waiter is already released, it might have found something on a poll *)
            Mutex.unlock mc.mutex;
            check_waiters mchan
          end
      end

let register_domain mchan =
  let id = Atomic.fetch_and_add mchan.next_domain_id 1 in
  assert(id < Array.length mchan.channels);
  id

let get_id_key mchan =
  let id = Domain.DLS.get id_key in
  if id >= 0 then id
  else begin
    let id = (register_domain mchan) in
    Domain.DLS.set id_key id;
    id
  end

let clear_id_key () =
  Domain.DLS.set id_key (-1)

let send mchan v =
  let id = (get_id_key mchan) in
  let res = Ws_deque.push mchan.channels.(id) v in
  check_waiters mchan;
  res

let rec recv_poll_loop mchan cur left =
  if left = 0 then None
  else begin
    match Ws_deque.steal mchan.channels.(Int.logand cur mchan.mask) with
      | Some _ as v -> v
      | None -> recv_poll_loop mchan (cur+1) (left-1)
  end

let recv_poll mchan =
  let id = (get_id_key mchan) in
  match Ws_deque.pop mchan.channels.(id) with
    | Some _ as v -> v
    | None ->
      recv_poll_loop mchan (id + 1) ((Array.length mchan.channels) - 1)

let rec recv mchan =
  match recv_poll mchan with
    | Some v -> v
    | None ->
      begin
        (* Didn't find anything, prepare to block:
         *  - enqueue our wait block in the waiter queue
         *  - check the queue again
         *  - go to sleep if our wait block has not been notified
         *  - when notified retry the recieve
         *)
        let status = ref Waiting in
        let mc = Domain.DLS.get mc_key in
        Chan.send mchan.waiters (status, mc);
        match recv_poll mchan with
          | Some v ->
            begin
              (* need to check the status as might take an item
                which is not the one an existing sender has woken us
                to take *)
              Mutex.lock mc.mutex;
              begin match !status with
              | Waiting -> (status := Released; Mutex.unlock mc.mutex)
              | Released ->
                (* we were simultaneously released from a sender;
                  so need to release a waiter *)
                (Mutex.unlock mc.mutex; check_waiters mchan)
              end;
              v
            end
          | None ->
            if !status = Waiting then begin
               Mutex.lock mc.mutex;
               while !status = Waiting do
                 Condition.wait mc.condition mc.mutex
               done;
               Mutex.unlock mc.mutex
            end;
            recv mchan
      end
