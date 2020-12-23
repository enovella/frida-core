namespace Frida.JDWP {
	public class Client : Object, AsyncInitable {
		public signal void closed ();

		public IOStream stream {
			get;
			construct;
		}

		public State state {
			get {
				return _state;
			}
		}

		private InputStream input;
		private OutputStream output;
		private Cancellable io_cancellable = new Cancellable ();

		private State _state = CREATED;
		private uint32 next_id = 1;
		private IDSizes id_sizes = new IDSizes.unknown ();
		private Gee.ArrayList<StopObserverEntry> on_stop = new Gee.ArrayList<StopObserverEntry> ();
		private Gee.ArrayQueue<Bytes> pending_writes = new Gee.ArrayQueue<Bytes> ();
		private Gee.Map<uint32, PendingReply> pending_replies = new Gee.HashMap<uint32, PendingReply> ();

		public enum State {
			CREATED,
			READY,
			CLOSED
		}

		private const string HANDSHAKE = "JDWP-Handshake";
		private const uint32 MAX_PACKET_SIZE = 10 * 1024 * 1024;

		public static async Client open (IOStream stream, Cancellable? cancellable = null) throws Error, IOError {
			var session = new Client (stream);

			try {
				yield session.init_async (Priority.DEFAULT, cancellable);
			} catch (GLib.Error e) {
				throw_api_error (e);
			}

			return session;
		}

		private Client (IOStream stream) {
			Object (stream: stream);
		}

		construct {
			input = stream.get_input_stream ();
			output = stream.get_output_stream ();
		}

		private async bool init_async (int io_priority, Cancellable? cancellable) throws Error, IOError {
			yield handshake (cancellable);
			process_incoming_packets.begin ();

			id_sizes = yield get_id_sizes (cancellable);

			change_state (READY);

			return true;
		}

		private void change_state (State new_state) {
			bool state_differs = new_state != _state;
			if (state_differs)
				_state = new_state;

			if (state_differs)
				notify_property ("state");
		}

		public async void close (Cancellable? cancellable) throws IOError {
			if (state == CLOSED)
				return;

			io_cancellable.cancel ();

			var source = new IdleSource ();
			source.set_callback (close.callback);
			source.attach (MainContext.get_thread_default ());
			yield;

			try {
				yield stream.close_async (Priority.DEFAULT, cancellable);
			} catch (IOError e) {
			}
		}

		public async ClassInfo get_class_by_signature (string signature, Cancellable? cancellable = null) throws Error, IOError {
			var candidates = yield get_classes_by_signature (signature, cancellable);
			if (candidates.is_empty)
				throw new Error.INVALID_ARGUMENT ("Class %s not found", signature);
			if (candidates.size > 1)
				throw new Error.INVALID_ARGUMENT ("Class %s is ambiguous", signature);
			return candidates.get (0);
		}

		public async Gee.List<ClassInfo> get_classes_by_signature (string signature, Cancellable? cancellable = null)
				throws Error, IOError {
			var command = make_command (VM, VMCommand.CLASSES_BY_SIGNATURE);
			command.append_utf8_string (signature);

			var reply = yield execute (command, cancellable);

			var result = new Gee.ArrayList<ClassInfo> ();
			int32 n = reply.read_int32 ();
			for (int32 i = 0; i != n; i++) {
				TypeTag kind = (TypeTag) reply.read_uint8 ();
				ReferenceTypeID type_id = reply.read_reference_type_id ();
				ClassStatus status = (ClassStatus) reply.read_int32 ();
				result.add (new ClassInfo (kind, type_id, status));
			}
			return result;
		}

		public async Gee.List<MethodInfo> get_methods (ReferenceTypeID type_id, Cancellable? cancellable = null)
				throws Error, IOError {
			var command = make_command (REFERENCE_TYPE, ReferenceTypeCommand.METHODS);
			command.append_reference_type_id (type_id);

			var reply = yield execute (command, cancellable);

			var result = new Gee.ArrayList<MethodInfo> ();
			int32 n = reply.read_int32 ();
			for (int32 i = 0; i != n; i++) {
				MethodID method_id = reply.read_method_id ();
				string name = reply.read_utf8_string ();
				string signature = reply.read_utf8_string ();
				int32 mod_bits = reply.read_int32 ();
				result.add (new MethodInfo (method_id, name, signature, mod_bits));
			}
			return result;
		}

		public async EventRequestID set_event_request (EventKind kind, SuspendPolicy suspend_policy, EventModifier[] modifiers,
				Cancellable? cancellable = null) throws Error, IOError {
			var command = make_command (EVENT_REQUEST, EventRequestCommand.SET);
			command
				.append_uint8 (kind)
				.append_uint8 (suspend_policy)
				.append_int32 (modifiers.length);
			foreach (var modifier in modifiers)
				modifier.serialize (command);

			var reply = yield execute (command, cancellable);

			return EventRequestID (reply.read_int32 ());
		}

		public async void clear_event_request (EventKind kind, EventRequestID request_id, Cancellable? cancellable = null)
				throws Error, IOError {
			var command = make_command (EVENT_REQUEST, EventRequestCommand.CLEAR);
			command
				.append_uint8 (kind)
				.append_int32 (request_id.handle);

			yield execute (command, cancellable);
		}

		public async void clear_all_breakpoints (Cancellable? cancellable = null) throws Error, IOError {
			var command = make_command (EVENT_REQUEST, EventRequestCommand.CLEAR_ALL_BREAKPOINTS);

			yield execute (command, cancellable);
		}

		private async void handshake (Cancellable? cancellable) throws Error, IOError {
			try {
				size_t n;

				unowned uint8[] raw_handshake = HANDSHAKE.data;
				yield output.write_all_async (raw_handshake, Priority.DEFAULT, cancellable, out n);

				var raw_reply = new uint8[HANDSHAKE.length];
				yield input.read_all_async (raw_reply, Priority.DEFAULT, cancellable, out n);

				if (Memory.cmp (raw_reply, raw_handshake, raw_reply.length) != 0)
					throw new Error.PROTOCOL ("Unexpected handshake reply");
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("%s".printf (e.message));
			}
		}

		private async IDSizes get_id_sizes (Cancellable? cancellable) throws Error, IOError {
			var command = make_command (VM, VMCommand.ID_SIZES);

			var reply = yield execute (command, cancellable);

			var field_id_size = reply.read_int32 ();
			var method_id_size = reply.read_int32 ();
			var object_id_size = reply.read_int32 ();
			var reference_type_id_size = reply.read_int32 ();
			var frame_id_size = reply.read_int32 ();
			return new IDSizes (field_id_size, method_id_size, object_id_size, reference_type_id_size, frame_id_size);
		}

		private CommandBuilder make_command (CommandSet command_set, uint8 command) {
			return new CommandBuilder (next_id++, command_set, command, id_sizes);
		}

		private async PacketReader execute (CommandBuilder command, Cancellable? cancellable) throws Error, IOError {
			if (state == CLOSED)
				throw new Error.INVALID_OPERATION ("Unable to perform command; connection is closed");

			var pending = new PendingReply (execute.callback);
			pending_replies[command.id] = pending;

			var cancel_source = new CancellableSource (cancellable);
			cancel_source.set_callback (() => {
				pending.complete_with_error (new IOError.CANCELLED ("Operation was cancelled"));
				return false;
			});
			cancel_source.attach (MainContext.get_thread_default ());

			write_bytes (command.build ());

			yield;

			cancel_source.destroy ();

			cancellable.set_error_if_cancelled ();

			var reply = pending.reply;
			if (reply == null)
				throw_local_error (pending.error);

			return reply;
		}

		private async void process_incoming_packets () {
			while (true) {
				try {
					var packet = yield read_packet ();

					dispatch_packet (packet);
				} catch (GLib.Error error) {
					change_state (CLOSED);

					foreach (var pending in pending_replies.values)
						pending.complete_with_error (error);
					pending_replies.clear ();

					foreach (var observer in on_stop.to_array ())
						observer.func ();

					closed ();

					return;
				}
			}
		}

		private async void process_pending_writes () {
			while (!pending_writes.is_empty) {
				Bytes current = pending_writes.peek_head ();

				try {
					size_t n;
					yield output.write_all_async (current.get_data (), Priority.DEFAULT, io_cancellable, out n);
				} catch (GLib.Error e) {
					return;
				}

				pending_writes.poll_head ();
			}
		}

		private void dispatch_packet (PacketReader packet) throws Error {
			packet.skip (sizeof (uint32));
			uint32 id = packet.read_uint32 ();
			packet.skip (sizeof (uint8));

			PendingReply? pending = pending_replies[id];
			if (pending != null) {
				var error_code = packet.read_uint16 ();

				if (error_code == 0)
					pending.complete_with_reply (packet);
				else
					pending.complete_with_error (new Error.NOT_SUPPORTED ("Command failed: %u", error_code));
			}
		}

		private async PacketReader read_packet () throws Error, IOError {
			try {
				size_t n;

				int header_size = 11;
				var raw_reply = new uint8[header_size];
				yield input.read_all_async (raw_reply, Priority.DEFAULT, io_cancellable, out n);

				uint32 reply_size = uint32.from_big_endian (*((uint32 *) raw_reply));
				if (reply_size != raw_reply.length) {
					if (reply_size < raw_reply.length)
						throw new Error.PROTOCOL ("Invalid packet length (too small)");
					if (reply_size > MAX_PACKET_SIZE)
						throw new Error.PROTOCOL ("Invalid packet length (too large)");

					raw_reply.resize ((int) reply_size);
					yield input.read_all_async (raw_reply[header_size:], Priority.DEFAULT, io_cancellable, out n);
				}

				return new PacketReader ((owned) raw_reply, id_sizes);
			} catch (GLib.Error e) {
				throw new Error.TRANSPORT ("%s".printf (e.message));
			}
		}

		private void write_bytes (Bytes bytes) {
			pending_writes.offer_tail (bytes);
			if (pending_writes.size == 1)
				process_pending_writes.begin ();
		}

		private static void throw_local_error (GLib.Error e) throws Error, IOError {
			if (e is Error)
				throw (Error) e;

			if (e is IOError)
				throw (IOError) e;

			assert_not_reached ();
		}

		private class StopObserverEntry {
			public SourceFunc? func;

			public StopObserverEntry (owned SourceFunc func) {
				this.func = (owned) func;
			}
		}

		private class PendingReply {
			private SourceFunc? handler;

			public PacketReader? reply {
				get;
				private set;
			}

			public GLib.Error? error {
				get;
				private set;
			}

			public PendingReply (owned SourceFunc handler) {
				this.handler = (owned) handler;
			}

			public void complete_with_reply (PacketReader? reply) {
				if (handler == null)
					return;
				this.reply = reply;
				handler ();
				handler = null;
			}

			public void complete_with_error (GLib.Error error) {
				if (handler == null)
					return;
				this.error = error;
				handler ();
				handler = null;
			}
		}
	}

	public enum TypeTag {
		CLASS     = 1,
		INTERFACE = 2,
		ARRAY     = 3;

		public string to_short_string () {
			return Marshal.enum_to_nick<TypeTag> (this).up ();
		}
	}

	public class ClassInfo : Object {
		public TypeTag ref_type_tag {
			get;
			construct;
		}

		public ReferenceTypeID type_id {
			get;
			construct;
		}

		public ClassStatus status {
			get;
			construct;
		}

		public ClassInfo (TypeTag ref_type_tag, ReferenceTypeID type_id, ClassStatus status) {
			Object (
				ref_type_tag: ref_type_tag,
				type_id: type_id,
				status: status
			);
		}

		public string to_string () {
			return "ClassInfo(ref_type_tag: %s, type_id: %s, status: %s)".printf (
				ref_type_tag.to_short_string (),
				type_id.to_string (),
				status.to_short_string ());
		}
	}

	[Flags]
	public enum ClassStatus {
		VERIFIED    = (1 << 0),
		PREPARED    = (1 << 1),
		INITIALIZED = (1 << 2),
		ERROR       = (1 << 3);

		public string to_short_string () {
			return this.to_string ().replace ("FRIDA_JDWP_CLASS_STATUS_", "");
		}
	}

	public class MethodInfo : Object {
		public MethodID id {
			get;
			construct;
		}

		public string name {
			get;
			construct;
		}

		public string signature {
			get;
			construct;
		}

		public int32 mod_bits {
			get;
			construct;
		}

		public MethodInfo (MethodID id, string name, string signature, int32 mod_bits) {
			Object (
				id: id,
				name: name,
				signature: signature,
				mod_bits: mod_bits
			);
		}

		public string to_string () {
			return "MethodInfo(id: %s, name: \"%s\", signature: \"%s\", mod_bits: 0x%08x)".printf (
				id.to_string (),
				name,
				signature,
				mod_bits);
		}
	}

	public struct ObjectID {
		public int64 handle {
			get;
			private set;
		}

		public ObjectID (int64 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return (handle != 0) ? handle.to_string () : "null";
		}
	}

	public struct ThreadID {
		public int64 handle {
			get;
			private set;
		}

		public ThreadID (int64 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return handle.to_string ();
		}
	}

	public struct ReferenceTypeID {
		public int64 handle {
			get;
			private set;
		}

		public ReferenceTypeID (int64 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return (handle != 0) ? handle.to_string () : "null";
		}
	}

	public struct MethodID {
		public int64 handle {
			get;
			private set;
		}

		public MethodID (int64 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return handle.to_string ();
		}
	}

	public struct FieldID {
		public int64 handle {
			get;
			private set;
		}

		public FieldID (int64 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return handle.to_string ();
		}
	}

	public enum EventKind {
		SINGLE_STEP                   = 1,
		BREAKPOINT                    = 2,
		FRAME_POP                     = 3,
		EXCEPTION                     = 4,
		USER_DEFINED                  = 5,
		THREAD_START                  = 6,
		THREAD_DEATH                  = 7,
		CLASS_PREPARE                 = 8,
		CLASS_UNLOAD                  = 9,
		CLASS_LOAD                    = 10,
		FIELD_ACCESS                  = 20,
		FIELD_MODIFICATION            = 21,
		EXCEPTION_CATCH               = 30,
		METHOD_ENTRY                  = 40,
		METHOD_EXIT                   = 41,
		METHOD_EXIT_WITH_RETURN_VALUE = 42,
		MONITOR_CONTENDED_ENTER       = 43,
		MONITOR_CONTENDED_ENTERED     = 44,
		MONITOR_WAIT                  = 45,
		MONITOR_WAITED                = 46,
		VM_START                      = 90,
		VM_DEATH                      = 99,
	}

	public enum SuspendPolicy {
		NONE         = 0,
		EVENT_THREAD = 1,
		ALL          = 2,
	}

	public abstract class EventModifier : Object {
		internal abstract void serialize (CommandBuilder builder);
	}

	public class CountModifier : EventModifier {
		public int32 count {
			get;
			construct;
		}

		public CountModifier (int32 count) {
			Object (count: count);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.COUNT)
				.append_int32 (count);
		}
	}

	public class ThreadOnlyModifier : EventModifier {
		public ThreadID thread {
			get;
			construct;
		}

		public ThreadOnlyModifier (ThreadID thread) {
			Object (thread: thread);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.THREAD_ONLY)
				.append_thread_id (thread);
		}
	}

	public class ClassOnlyModifier : EventModifier {
		public ReferenceTypeID clazz {
			get;
			construct;
		}

		public ClassOnlyModifier (ReferenceTypeID clazz) {
			Object (clazz: clazz);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.CLASS_ONLY)
				.append_reference_type_id (clazz);
		}
	}

	public class ClassMatchModifier : EventModifier {
		public string class_pattern {
			get;
			construct;
		}

		public ClassMatchModifier (string class_pattern) {
			Object (class_pattern: class_pattern);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.CLASS_MATCH)
				.append_utf8_string (class_pattern);
		}
	}

	public class ClassExcludeModifier : EventModifier {
		public string class_pattern {
			get;
			construct;
		}

		public ClassExcludeModifier (string class_pattern) {
			Object (class_pattern: class_pattern);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.CLASS_EXCLUDE)
				.append_utf8_string (class_pattern);
		}
	}

	public class LocationOnlyModifier : EventModifier {
		public TypeTag tag {
			get;
			construct;
		}

		public ReferenceTypeID rtype {
			get;
			construct;
		}

		public MethodID method {
			get;
			construct;
		}

		public uint64 index {
			get;
			construct;
		}

		public LocationOnlyModifier (TypeTag tag, ReferenceTypeID rtype, MethodID method, uint64 index = 0) {
			Object (
				tag: tag,
				rtype: rtype,
				method: method,
				index: index
			);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.LOCATION_ONLY)
				.append_uint8 (tag)
				.append_reference_type_id (rtype)
				.append_method_id (method)
				.append_uint64 (index);
		}
	}

	public class ExceptionOnlyModifier : EventModifier {
		public ReferenceTypeID exception_or_null {
			get;
			construct;
		}

		public bool caught {
			get;
			construct;
		}

		public bool uncaught {
			get;
			construct;
		}

		public ExceptionOnlyModifier (ReferenceTypeID exception_or_null, bool caught, bool uncaught) {
			Object (
				exception_or_null: exception_or_null,
				caught: caught,
				uncaught: uncaught
			);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.EXCEPTION_ONLY)
				.append_reference_type_id (exception_or_null)
				.append_bool (caught)
				.append_bool (uncaught);
		}
	}

	public class FieldOnlyModifier : EventModifier {
		public ReferenceTypeID declaring {
			get;
			construct;
		}

		public FieldID field {
			get;
			construct;
		}

		public FieldOnlyModifier (ReferenceTypeID declaring, FieldID field) {
			Object (
				declaring: declaring,
				field: field
			);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.FIELD_ONLY)
				.append_reference_type_id (declaring)
				.append_field_id (field);
		}
	}

	public class StepModifier : EventModifier {
		public ThreadID thread {
			get;
			construct;
		}

		public StepSize step_size {
			get;
			construct;
		}

		public StepDepth step_depth {
			get;
			construct;
		}

		public StepModifier (ThreadID thread, StepSize step_size, StepDepth step_depth) {
			Object (
				thread: thread,
				step_size: step_size,
				step_depth: step_depth
			);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.STEP)
				.append_thread_id (thread)
				.append_int32 (step_size)
				.append_int32 (step_depth);
		}
	}

	public enum StepSize {
		MIN  = 0,
		LINE = 1,
	}

	public enum StepDepth {
		INTO = 0,
		OVER = 1,
		OUT  = 2,
	}

	public class InstanceOnlyModifier : EventModifier {
		public ObjectID instance {
			get;
			construct;
		}

		public InstanceOnlyModifier (ObjectID instance) {
			Object (instance: instance);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.INSTANCE_ONLY)
				.append_object_id (instance);
		}
	}

	public class SourceNameMatchModifier : EventModifier {
		public string source_name_pattern {
			get;
			construct;
		}

		public SourceNameMatchModifier (string source_name_pattern) {
			Object (source_name_pattern: source_name_pattern);
		}

		internal override void serialize (CommandBuilder builder) {
			builder
				.append_uint8 (EventModifierKind.SOURCE_NAME_MATCH)
				.append_utf8_string (source_name_pattern);
		}
	}

	private enum EventModifierKind {
		COUNT             = 1,
		THREAD_ONLY       = 3,
		CLASS_ONLY        = 4,
		CLASS_MATCH       = 5,
		CLASS_EXCLUDE     = 6,
		LOCATION_ONLY     = 7,
		EXCEPTION_ONLY    = 8,
		FIELD_ONLY        = 9,
		STEP              = 10,
		INSTANCE_ONLY     = 11,
		SOURCE_NAME_MATCH = 12,
	}

	public struct EventRequestID {
		public int32 handle {
			get;
			private set;
		}

		public EventRequestID (int32 handle) {
			this.handle = handle;
		}

		public string to_string () {
			return handle.to_string ();
		}
	}

	private enum CommandSet {
		VM             = 1,
		REFERENCE_TYPE = 2,
		EVENT_REQUEST  = 15,
	}

	private enum VMCommand {
		CLASSES_BY_SIGNATURE = 2,
		ID_SIZES             = 7,
	}

	private enum ReferenceTypeCommand {
		METHODS = 5,
	}

	private enum EventRequestCommand {
		SET                   = 1,
		CLEAR                 = 2,
		CLEAR_ALL_BREAKPOINTS = 3,
	}

	private class CommandBuilder : PacketBuilder {
		public CommandBuilder (uint32 id, CommandSet command_set, uint8 command, IDSizes id_sizes) {
			base (id, 0, id_sizes);

			append_uint8 (command_set);
			append_uint8 (command);
		}
	}

	private class PacketBuilder {
		public uint32 id {
			get;
			private set;
		}

		public size_t offset {
			get {
				return cursor;
			}
		}

		private ByteArray buffer = new ByteArray.sized (64);
		private size_t cursor = 0;

		private IDSizes id_sizes;

		public PacketBuilder (uint32 id, uint8 flags, IDSizes id_sizes) {
			this.id = id;
			this.id_sizes = id_sizes;

			uint32 length_placeholder = 0;
			append_uint32 (length_placeholder);
			append_uint32 (id);
			append_uint8 (flags);
		}

		public unowned PacketBuilder append_uint8 (uint8 val) {
			*(get_pointer (cursor, sizeof (uint8))) = val;
			cursor += (uint) sizeof (uint8);
			return this;
		}

		public unowned PacketBuilder append_int32 (int32 val) {
			*((int32 *) get_pointer (cursor, sizeof (int32))) = val.to_big_endian ();
			cursor += (uint) sizeof (int32);
			return this;
		}

		public unowned PacketBuilder append_uint32 (uint32 val) {
			*((uint32 *) get_pointer (cursor, sizeof (uint32))) = val.to_big_endian ();
			cursor += (uint) sizeof (uint32);
			return this;
		}

		public unowned PacketBuilder append_int64 (int64 val) {
			*((int64 *) get_pointer (cursor, sizeof (int64))) = val.to_big_endian ();
			cursor += (uint) sizeof (int64);
			return this;
		}

		public unowned PacketBuilder append_uint64 (uint64 val) {
			*((uint64 *) get_pointer (cursor, sizeof (uint64))) = val.to_big_endian ();
			cursor += (uint) sizeof (uint64);
			return this;
		}

		public unowned PacketBuilder append_bool (bool val) {
			return append_uint8 ((uint8) val);
		}

		public unowned PacketBuilder append_utf8_string (string str) {
			append_uint32 (str.length);

			uint size = str.length;
			Memory.copy (get_pointer (cursor, size), str, size);
			cursor += size;

			return this;
		}

		public unowned PacketBuilder append_object_id (ObjectID object) {
			return append_handle (object.handle, id_sizes.get_object_id_size_or_die ());
		}

		public unowned PacketBuilder append_thread_id (ThreadID thread) {
			return append_handle (thread.handle, id_sizes.get_object_id_size_or_die ());
		}

		public unowned PacketBuilder append_reference_type_id (ReferenceTypeID type) {
			return append_handle (type.handle, id_sizes.get_reference_type_id_size_or_die ());
		}

		public unowned PacketBuilder append_method_id (MethodID method) {
			return append_handle (method.handle, id_sizes.get_method_id_size_or_die ());
		}

		public unowned PacketBuilder append_field_id (FieldID field) {
			return append_handle (field.handle, id_sizes.get_field_id_size_or_die ());
		}

		private unowned PacketBuilder append_handle (int64 val, size_t size) {
			switch (size) {
				case 4:
					return append_int32 ((int32) val);
				case 8:
					return append_int64 (val);
				default:
					assert_not_reached ();
			}
		}

		private uint8 * get_pointer (size_t offset, size_t n) {
			size_t minimum_size = offset + n;
			if (buffer.len < minimum_size)
				buffer.set_size ((uint) minimum_size);

			return (uint8 *) buffer.data + offset;
		}

		public Bytes build () {
			*((uint32 *) get_pointer (0, sizeof (uint32))) = buffer.len.to_big_endian ();
			return ByteArray.free_to_bytes ((owned) buffer);
		}
	}

	private class PacketReader {
		public size_t available_bytes {
			get {
				return end - cursor;
			}
		}

		private uint8[] data;
		private uint8 * cursor;
		private uint8 * end;

		private IDSizes id_sizes;

		public PacketReader (owned uint8[] data, IDSizes id_sizes) {
			this.data = (owned) data;
			this.cursor = (uint8 *) this.data;
			this.end = cursor + this.data.length;

			this.id_sizes = id_sizes;
		}

		public void skip (size_t n) throws Error {
			check_available (n);
			cursor += n;
		}

		public uint8 read_uint8 () throws Error {
			const size_t n = sizeof (uint8);
			check_available (n);

			uint8 val = *cursor;
			cursor += n;

			return val;
		}

		public uint16 read_uint16 () throws Error {
			const size_t n = sizeof (uint16);
			check_available (n);

			uint16 val = uint16.from_big_endian (*((uint16 *) cursor));
			cursor += n;

			return val;
		}

		public int32 read_int32 () throws Error {
			const size_t n = sizeof (int32);
			check_available (n);

			int32 val = int32.from_big_endian (*((int32 *) cursor));
			cursor += n;

			return val;
		}

		public uint32 read_uint32 () throws Error {
			const size_t n = sizeof (uint32);
			check_available (n);

			uint32 val = uint32.from_big_endian (*((uint32 *) cursor));
			cursor += n;

			return val;
		}

		public int64 read_int64 () throws Error {
			const size_t n = sizeof (int64);
			check_available (n);

			int64 val = int64.from_big_endian (*((int64 *) cursor));
			cursor += n;

			return val;
		}

		public string read_utf8_string () throws Error {
			size_t size = read_uint32 ();
			check_available (size);

			unowned string data = (string) cursor;
			string str = data.substring (0, (long) size);
			cursor += size;

			return str;
		}

		public ReferenceTypeID read_reference_type_id () throws Error {
			return ReferenceTypeID (read_handle (id_sizes.get_reference_type_id_size ()));
		}

		public MethodID read_method_id () throws Error {
			return MethodID (read_handle (id_sizes.get_method_id_size ()));
		}

		private int64 read_handle (size_t size) throws Error {
			switch (size) {
				case 4:
					return read_int32 ();
				case 8:
					return read_int64 ();
				default:
					assert_not_reached ();
			}
		}

		private void check_available (size_t n) throws Error {
			if (cursor + n > end)
				throw new Error.PROTOCOL ("Invalid JDWP packet");
		}
	}

	private class IDSizes {
		private bool valid;
		private int field_id_size = -1;
		private int method_id_size = -1;
		private int object_id_size = -1;
		private int reference_type_id_size = -1;
		private int frame_id_size = -1;

		public IDSizes (int field_id_size, int method_id_size, int object_id_size, int reference_type_id_size, int frame_id_size) {
			this.field_id_size = field_id_size;
			this.method_id_size = method_id_size;
			this.object_id_size = object_id_size;
			this.reference_type_id_size = reference_type_id_size;
			this.frame_id_size = frame_id_size;

			valid = true;
		}

		public IDSizes.unknown () {
			valid = false;
		}

		public size_t get_field_id_size () throws Error {
			check ();
			return field_id_size;
		}

		public size_t get_field_id_size_or_die () {
			assert (valid);
			return field_id_size;
		}

		public size_t get_method_id_size () throws Error {
			check ();
			return method_id_size;
		}

		public size_t get_method_id_size_or_die () {
			assert (valid);
			return method_id_size;
		}

		public size_t get_object_id_size () throws Error {
			check ();
			return object_id_size;
		}

		public size_t get_object_id_size_or_die () {
			assert (valid);
			return object_id_size;
		}

		public size_t get_reference_type_id_size () throws Error {
			check ();
			return reference_type_id_size;
		}

		public size_t get_reference_type_id_size_or_die () {
			assert (valid);
			return reference_type_id_size;
		}

		private void check () throws Error {
			if (!valid)
				throw new Error.PROTOCOL ("ID sizes not known");
		}
	}
}
