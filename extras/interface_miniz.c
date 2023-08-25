#define MINIZ_NO_ARCHIVE_APIS
#include "miniz.c"

// Allocate a stream that will keep a fixed destination for newly compressed data
mz_streamp alloc_miniz_encoder(char* dst, size_t dst_len) {
	mz_streamp stream = malloc( sizeof(mz_stream) );

	if (!stream)
		return NULL;

	stream->next_in		= 0;
	stream->avail_in	= 0;
	stream->total_in	= 0;
	stream->next_out	= dst;
	stream->avail_out	= dst_len;
	stream->total_out	= 0;
	stream->msg			= 0;
	stream->state		= 0;
	stream->zalloc		= 0;
	stream->zfree		= 0;
	stream->opaque		= 0;
	stream->data_type	= 0;
	stream->adler		= 0;
	stream->reserved	= 0;

	int status = mz_deflateInit2( stream, 3, MZ_DEFLATED, -MZ_DEFAULT_WINDOW_BITS, 9, MZ_DEFAULT_STRATEGY );
	//									  \_____________________				   \_______
	//									   COMPRESSION LEVEL 1-9					IGNORED

	if (status < 0)
		return NULL;

	return stream;
}

// Allocate a stream that will keep a fixed destination for newly decompressed data
mz_streamp alloc_miniz_decoder(char* dst, size_t dst_len) {
	mz_streamp stream = malloc( sizeof(mz_stream) );

	if (!stream)
		return NULL;

	stream->next_in		= 0;
	stream->avail_in	= 0;
	stream->total_in	= 0;
	stream->next_out	= dst;
	stream->avail_out	= dst_len;
	stream->total_out	= 0;
	stream->msg			= 0;
	stream->state		= 0;
	stream->zalloc		= 0;
	stream->zfree		= 0;
	stream->opaque		= 0;
	stream->data_type	= 0;
	stream->adler		= 0;
	stream->reserved	= 0;

	int status = mz_inflateInit2( stream, -MZ_DEFAULT_WINDOW_BITS );

	if (status < 0)
		return NULL;

	return stream;
}

// Free a stream
void free_miniz_stream(mz_streamp stream) {
	free(stream);
}

// Perform the compression/decompression from source to destination, if destination not yet full
static int provide_miniz_input(mz_streamp stream, char* src, size_t src_len, int fn(mz_streamp, int)) {
	if (src && src_len) {
		stream->next_in		= src;
		stream->avail_in	= src_len;
	}

	int status = fn( stream, MZ_NO_FLUSH );

	// Triggered if the input is large enough to saturate the destination buffer
	// In this scenarion, status == 0
	if (stream->avail_in > 0 && status == 0) {
		return 3; // DESTINATION_BUFFER_SATURATED
	}

	return status;
}

int provide_miniz_encoder_input(mz_streamp stream, char* src, size_t src_len) { return provide_miniz_input(stream, src, src_len, mz_deflate); }
int provide_miniz_decoder_input(mz_streamp stream, char* src, size_t src_len) { return provide_miniz_input(stream, src, src_len, mz_inflate); }

// Signal that there will be no new data and it's time to terminate the bitstream
int finish_miniz_encoder_input(mz_streamp stream) { return mz_deflate( stream, MZ_FINISH ); }
int finish_miniz_decoder_input(mz_streamp stream) { return mz_inflate( stream, MZ_FINISH ); }

// Returns the amount of bytes currently waiting at the destination, and marks the destination to be overwritten
// You must save the data that's waiting at the destination after calling this if you do not wish to see it lost
int harvest_miniz_output(mz_streamp stream) {
	int pending = stream->total_out;

	stream->next_out	-= pending;
	stream->avail_out	+= pending;
	stream->total_out	= 0;

	return pending;
}

// Returns the amount of bytes sitting unused in the source buffer
int number_miniz_unused_bytes(mz_streamp stream) {
	return stream->avail_in;
}
