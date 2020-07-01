// This is a hacky way of doing Thread Local Storage
// __thread attribute makes this variable be unique to current thread

__thread struct _m_Parameters_ServeThreadParameters_obj* param_store;

void set_thread_parameters(struct _m_Parameters_ServeThreadParameters_obj* parameters) {
	param_store = parameters;
}

struct _m_Parameters_ServeThreadParameters_obj* get_thread_parameters() {
	return param_store;
}
