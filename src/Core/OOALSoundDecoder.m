/*

OOALSoundDecoder.m


OOALSound - OpenAL sound implementation for Oolite.
Copyright (C) 2005-2013 Jens Ayton

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

*/

#import "OOALSoundDecoder.h"
#import "NSDataOOExtensions.h"
#import <vorbis/vorbisfile.h>
#import "OOLogging.h"
#import "unzip.h"

#define ZIP_BUFFER_SIZE 8192

enum
{
	kMaxDecodeSize			= 1 << 20		// 2^20 frames = 4 MB
};

static void MixDown(float *inChan1, float *inChan2, float *outMix, size_t inCount);
static size_t OOReadOXZVorbis (void *ptr, size_t size, size_t nmemb, void *datasource);
static int OOCloseOXZVorbis (void *datasource);

@interface OOALSoundVorbisCodec: OOALSoundDecoder
{
	OggVorbis_File			_vf;
	NSString				*_name;
	BOOL					_atEnd;
@public
	unzFile					uf;
	size_t					oxzPointer;
}

- (NSDictionary *)comments;

@end


@implementation OOALSoundDecoder

- (id)initWithPath:(NSString *)inPath
{
	[self release];
	self = nil;
	
	if ([[inPath pathExtension] isEqual:@"ogg"])
	{
		self = [[OOALSoundVorbisCodec alloc] initWithPath:inPath];
	}
	
	return self;
}


+ (OOALSoundDecoder *)codecWithPath:(NSString *)inPath
{
	if ([[inPath pathExtension] isEqual:@"ogg"])
	{
		return [[[OOALSoundVorbisCodec alloc] initWithPath:inPath] autorelease];
	}
	return nil;
}


- (size_t)streamStereoToBufferL:(float *)ioBufferL bufferR:(float *)ioBufferR maxFrames:(size_t)inMax
{
	return 0;
}


- (BOOL)readMonoCreatingBuffer:(float **)outBuffer withFrameCount:(size_t *)outSize
{
	if (NULL != outBuffer) *outBuffer = NULL;
	if (NULL != outSize) *outSize = 0;
	
	return NO;
}


- (BOOL)readStereoCreatingLeftBuffer:(float **)outLeftBuffer rightBuffer:(float **)outRightBuffer withFrameCount:(size_t *)outSize
{
	if (NULL != outLeftBuffer) *outLeftBuffer = NULL;
	if (NULL != outRightBuffer) *outRightBuffer = NULL;
	if (NULL != outSize) *outSize = 0;
	
	return NO;
}


- (size_t)sizeAsBuffer
{
	return 0;
}


- (BOOL)isStereo
{
	return NO;
}


- (long)sampleRate
{
	return 0;
}


- (BOOL)atEnd
{
	return YES;
}


- (void)rewindToBeginning
{
	
}


- (BOOL)scanToOffset:(uint64_t)inOffset
{
	return NO;
}


- (NSString *)name
{
	return @"";
}

@end


@implementation OOALSoundVorbisCodec

- (id)initWithPath:(NSString *)path
{
	BOOL				OK = NO;
	unsigned i, cl;
	NSArray *components = [path pathComponents];
	cl = [components count];
	for (i = 0 ; i < cl ; i++)
	{
		NSString *component = [components objectAtIndex:i];
		if ([[[component pathExtension] lowercaseString] isEqualToString:@"oxz"])
		{
			break;
		}
	}
	// if i == cl then the path is entirely uncompressed
	if (i == cl)
	{
		/* Get vorbis data from a standard file stream */
		int					err;
		FILE				*file;
	
		if ((self = [super init]))
		{
			_name = [[path lastPathComponent] retain];
		
			if (nil != path)
			{
				file = fopen([path UTF8String], "rb");
				if (NULL != file) 
				{
					err = ov_open_callbacks(file, &_vf, NULL, 0, OV_CALLBACKS_DEFAULT);
					if (0 == err)
					{
						OK = YES;
					}
				}
			}
		
			if (!OK)
			{
				[self release];
				self = nil;
			}
		}
	}
	else
	{
		NSRange range;
		range.location = 0; range.length = i+1;
		NSString *zipFile = [NSString pathWithComponents:[components subarrayWithRange:range]];
		range.location = i+1; range.length = cl-(i+1);
		NSString *containedFile = [NSString pathWithComponents:[components subarrayWithRange:range]];
		
		const char* zipname = [zipFile cStringUsingEncoding:NSUTF8StringEncoding];
		if (zipname != NULL)
		{
			uf = unzOpen64(zipname);
			oxzPointer = 0;
		}
		if (uf == NULL)
		{
			OOLog(kOOLogFileNotFound, @"Could not unzip OXZ at %@", zipFile);
			[self release];
			self = nil;
		}
		else 
		{
			const char* filename = [containedFile cStringUsingEncoding:NSUTF8StringEncoding];
			// unzLocateFile(*, *, 1) = case-sensitive extract
			if (unzLocateFile(uf, filename, 1) != UNZ_OK)
			{
				unzClose(uf);
				[self release];
				self = nil;
			}
			else
			{
				int err = UNZ_OK;
				unz_file_info64 file_info = {0};
				err = unzGetCurrentFileInfo64(uf, &file_info, NULL, 0, NULL, 0, NULL, 0);
				if (err != UNZ_OK)
				{
					unzClose(uf);
					OOLog(kOOLogFileNotFound, @"Could not get properties of %@ within OXZ at %@", containedFile, zipFile);
					[self release];
					self = nil;
				}
				else
				{
					err = unzOpenCurrentFile(uf);
					if (err != UNZ_OK)
					{
						unzClose(uf);
						OOLog(kOOLogFileNotFound, @"Could not read %@ within OXZ at %@", containedFile, zipFile);
						[self release];
						self = nil;
					}
					else
					{
				
						ov_callbacks _callbacks = {
							OOReadOXZVorbis, // read sequentially
							NULL, // no seek
							OOCloseOXZVorbis, // close file
							NULL, // no tell
						};
						err = ov_open_callbacks(self, &_vf, NULL, 0, _callbacks);
						if (0 == err)
						{
							OK = YES;
						}
						if (!OK)
						{
							unzClose(uf);
							[self release];
							self = nil;
						}
					}
				}
			}
		}
	}
	
	return self;
}


- (void)dealloc
{
	[_name release];
	ov_clear(&_vf);
	
	[super dealloc];
}


- (NSDictionary *)comments
{
	vorbis_comment			*comments;
	unsigned				i, count;
	NSMutableDictionary		*result = nil;
	NSString				*comment, *key, *value;
	NSRange					range;
	
	comments = ov_comment(&_vf, -1);
	if (NULL != comments)
	{
		count = comments->comments;
		if (0 != count)
		{
			result = [NSMutableDictionary dictionaryWithCapacity:count];
			for (i = 0; i != count; ++i)
			{
				comment = [[NSString alloc] initWithBytesNoCopy:comments->user_comments[i] length:comments->comment_lengths[i] encoding:NSUTF8StringEncoding freeWhenDone:NO];
				range = [comment rangeOfString:@"="];
				if (0 != range.length)
				{
					key = [comment substringToIndex:range.location];
					value = [comment substringFromIndex:range.location + 1];
				}
				else
				{
					key = comment;
					value = @"";
				}
				[result setObject:value forKey:key];
				
				[comment release];
			}
		}
	}
	
	return result;
}


- (BOOL)readMonoCreatingBuffer:(float **)outBuffer withFrameCount:(size_t *)outSize
{
	float					*buffer = NULL, *dst, **src;
	size_t					sizeInFrames = 0;
	int						remaining;
	unsigned				chanCount;
	long					framesRead;
	ogg_int64_t				totalSizeInFrames;
	BOOL					OK = YES;
	
	if (NULL != outBuffer) *outBuffer = NULL;
	if (NULL != outSize) *outSize = 0;
	if (NULL == outBuffer || NULL == outSize) OK = NO;
	
	if (OK)
	{
		totalSizeInFrames = ov_pcm_total(&_vf, -1);
		assert ((uint64_t)totalSizeInFrames < (uint64_t)SIZE_MAX);	// Should have been checked by caller
		sizeInFrames = (size_t)totalSizeInFrames;
	}
	
	if (OK)
	{
		buffer = malloc(sizeof (float) * sizeInFrames);
		if (!buffer) OK = NO;
	}
	
	if (OK && sizeInFrames)
	{
		remaining = (int)MIN(sizeInFrames, (size_t)INT_MAX);
		dst = buffer;
		
		do
		{
			chanCount = ov_info(&_vf, -1)->channels;
			framesRead = ov_read_float(&_vf, &src, remaining, NULL);
			if (framesRead <= 0)
			{
				if (OV_HOLE == framesRead) continue;
				//else:
				break;
			}
			
			if (1 == chanCount) bcopy(src[0], dst, sizeof (float) * framesRead);
			else MixDown(src[0], src[1], dst, framesRead);
			
			remaining -= framesRead;
			dst += framesRead;
		} while (0 != remaining);
		
		sizeInFrames -= remaining;	// In case we stopped at an error
	}
	
	if (OK)
	{
		*outBuffer = buffer;
		*outSize = sizeInFrames;
	}
	else
	{
		if (buffer) free(buffer);
	}
	return OK;
}


- (BOOL)readStereoCreatingLeftBuffer:(float **)outLeftBuffer rightBuffer:(float **)outRightBuffer withFrameCount:(size_t *)outSize
{
	float					*bufferL = NULL, *bufferR = NULL, *dstL, *dstR, **src;
	size_t					sizeInFrames = 0;
	int						remaining;
	unsigned				chanCount;
	long					framesRead;
	ogg_int64_t				totalSizeInFrames;
	BOOL					OK = YES;
	
	if (NULL != outLeftBuffer) *outLeftBuffer = NULL;
	if (NULL != outRightBuffer) *outRightBuffer = NULL;
	if (NULL != outSize) *outSize = 0;
	if (NULL == outLeftBuffer || NULL == outRightBuffer || NULL == outSize) OK = NO;
	
	if (OK)
	{
		totalSizeInFrames = ov_pcm_total(&_vf, -1);
		assert ((uint64_t)totalSizeInFrames < (uint64_t)SIZE_MAX);	// Should have been checked by caller
		sizeInFrames = (size_t)totalSizeInFrames;
	}
	
	if (OK)
	{
		bufferL = malloc(sizeof (float) * sizeInFrames);
		if (!bufferL) OK = NO;
	}
	
	if (OK)
	{
		bufferR = malloc(sizeof (float) * sizeInFrames);
		if (!bufferR) OK = NO;
	}
	
	if (OK && sizeInFrames)
	{
		remaining = (int)MIN(sizeInFrames, (size_t)INT_MAX);
		dstL = bufferL;
		dstR = bufferR;
		
		do
		{
			chanCount = ov_info(&_vf, -1)->channels;
			framesRead = ov_read_float(&_vf, &src, remaining, NULL);
			if (framesRead <= 0)
			{
				if (OV_HOLE == framesRead) continue;
				//else:
				break;
			}
			
			bcopy(src[0], dstL, sizeof (float) * framesRead);
			if (1 == chanCount) bcopy(src[0], dstR, sizeof (float) * framesRead);
			else bcopy(src[1], dstR, sizeof (float) * framesRead);
			
			remaining -= framesRead;
			dstL += framesRead;
			dstR += framesRead;
		} while (0 != remaining);
		
		sizeInFrames -= remaining;	// In case we stopped at an error
	}
	
	if (OK)
	{
		*outLeftBuffer = bufferL;
		*outRightBuffer = bufferR;
		*outSize = sizeInFrames;
	}
	else
	{
		if (bufferL) free(bufferL);
		if (bufferR) free(bufferR);
	}
	return OK;
}


- (size_t)streamStereoToBufferL:(float *)ioBufferL bufferR:(float *)ioBufferR maxFrames:(size_t)inMax
{
	float					**src;
	unsigned				chanCount;
	long					framesRead;
	size_t					size;
	int						remaining;
	unsigned				rightChan;
	
	// Note: for our purposes, a frame is a set of one sample for each channel.
	if (NULL == ioBufferL || NULL == ioBufferR || 0 == inMax) return 0;
	if (_atEnd) return inMax;
	
	remaining = (int)MIN(inMax, (size_t)INT_MAX);
	do
	{
		chanCount = ov_info(&_vf, -1)->channels;
		framesRead = ov_read_float(&_vf, &src, remaining, NULL);
		if (framesRead <= 0)
		{
			if (OV_HOLE == framesRead) continue;
			//else:
			_atEnd = YES;
			break;
		}
		
		size = sizeof (float) * framesRead;
		
		rightChan = (1 == chanCount) ? 0 : 1;
		bcopy(src[0], ioBufferL, size);
		bcopy(src[rightChan], ioBufferR, size);
		
		remaining -= framesRead;
		ioBufferL += framesRead;
		ioBufferR += framesRead;
	} while (0 != remaining);
	
	return inMax - remaining;
}


- (size_t)sizeAsBuffer
{
	ogg_int64_t				size;
	
	size = ov_pcm_total(&_vf, -1);
	size *= sizeof(float) * ([self isStereo] ? 2 : 1);
	if ((uint64_t)SIZE_MAX < (uint64_t)size) size = (ogg_int64_t)SIZE_MAX;
	return (size_t)size;
}


- (BOOL)isStereo
{
	return 1 < ov_info(&_vf, -1)->channels;
}


- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@ %p>{\"%@\", comments=%@}", [self className], self, _name, [self comments]];
}


- (long)sampleRate
{
	return ov_info(&_vf, -1)->rate;
}


- (BOOL)atEnd
{
	return _atEnd;
}


- (void)rewindToBeginning
{
	if (!ov_pcm_seek(&_vf, 0)) _atEnd = NO;
}


- (BOOL)scanToOffset:(uint64_t)inOffset
{
	if (!ov_pcm_seek(&_vf, inOffset))
	{
		_atEnd = NO;
		return YES;
	}
	else return NO;
}


- (NSString *)name
{
	return [[_name retain] autorelease];
}

@end


// TODO: optimise, vectorise
static void MixDown(float *inChan1, float *inChan2, float *outMix, size_t inCount)
{
	while (inCount--)
	{
		*outMix++ = (*inChan1++ + *inChan2++) * 0.5f;
	}
}


static size_t OOReadOXZVorbis (void *ptr, size_t size, size_t nmemb, void *datasource)
{
	OOALSoundVorbisCodec *src = (OOALSoundVorbisCodec *)datasource;
	size_t toRead = size*nmemb;
	void *buf = (void*)malloc(toRead);
	int err = UNZ_OK;
	err = unzReadCurrentFile(src->uf, buf, toRead);
	if (err > 0)
	{
		memcpy(ptr, buf, err);
	}
	if (err < 0)
	{
		return OV_EREAD;
	}
	return err;
}


static int OOCloseOXZVorbis (void *datasource)
{
	OOALSoundVorbisCodec *src = (OOALSoundVorbisCodec *)datasource;
	unzClose(src->uf);
	return 0;
}

// TODO: implement seek/tell functions for OXZ datastream
