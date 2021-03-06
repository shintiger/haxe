open Globals
open EvalContext
open EvalDebugMisc
open EvalExceptions
open EvalValue

module Deque = struct
	let create () = {
		dvalues = [];
		dmutex = Mutex.create();
	}

	let add this i =
		Mutex.lock this.dmutex;
		this.dvalues <- this.dvalues @ [i];
		Mutex.unlock this.dmutex

	let pop this blocking =
		let rec loop () =
			Mutex.lock this.dmutex;
			match this.dvalues with
			| v :: vl ->
				this.dvalues <- vl;
				Mutex.unlock this.dmutex;
				Some v
			| [] ->
				if not blocking then begin
					Mutex.unlock this.dmutex;
					None
				end else begin
					Mutex.unlock this.dmutex;
					Thread.yield();
					loop()
				end
		in
		loop()

	let push this i =
		Mutex.lock this.dmutex;
		this.dvalues <- i :: this.dvalues;
		Mutex.unlock this.dmutex
end

let create_eval thread = {
	env = None;
	thread = thread;
	debug_channel = Event.new_channel ();
	debug_state = DbgRunning;
	breakpoint = make_breakpoint 0 0 BPDisabled BPAny None;
	caught_types = Hashtbl.create 0;
	last_return = None;
	caught_exception = vnull;
}

let spawn ctx f =
	let f thread =
		let id = Thread.id (Thread.self()) in
		let maybe_send_thread_event reason = match ctx.debug.debug_socket with
			| Some socket ->
				socket.connection.send_thread_event id reason
			| None ->
				()
		in
		let new_eval = create_eval thread in
		ctx.evals <- IntMap.add id new_eval ctx.evals;
		let close () =
			ctx.evals <- IntMap.remove id ctx.evals;
			maybe_send_thread_event "exited";
		in
		try
			maybe_send_thread_event "started";
			ignore(f ());
			close();
		with
		| RunTimeException(v,stack,p) ->
			let msg = get_exc_error_message ctx v stack p in
			prerr_endline msg;
			close();
		| Sys_exit i ->
			close();
			exit i;
		| exc ->
			close();
			raise exc
	in
	let thread = {
		tthread = Obj.magic ();
		tstorage = IntMap.empty;
		tdeque = Deque.create();
	} in
	thread.tthread <- Thread.create f thread;
	thread