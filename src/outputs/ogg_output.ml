(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2008 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

 (** Abstract class for ogg outputs. *)

type create_encoder = Ogg_encoder.t -> (string*string) list -> Nativeint.t
(** Encode parameters: [ogg_encoder track_id frame offset length] *)
type encode = Ogg_encoder.t -> Nativeint.t -> Frame.t -> int -> int -> unit
type ogg_track = (Nativeint.t option ref)*create_encoder*encode

(** Helper to encode audio *)
let encode_audio ~stereo ~src_freq ~dst_freq () = 
  let tmp =
    if stereo then
      [||]
    else
      Float_pcm.create_buffer 1 (Fmt.samples_per_frame())
  in
  let encode encoder id frame ofs len = 
    let b = AFrame.get_float_pcm frame in
    let ofs = Fmt.samples_of_ticks ofs in
    let len = Fmt.samples_of_ticks len in
    let b =
      if stereo then b else begin
        for i = ofs to ofs+len-1 do
          let n = Fmt.channels () in
          let f i =
            Array.fold_left (fun x y -> x +. y.(i)) 0. b
          in
          tmp.(0).(i) <- f i /. (float_of_int n)
        done ;
        tmp
      end
    in
    let buf,ofs,len =
      if src_freq <> dst_freq then
        let b = Float_pcm.resample
          (dst_freq /. src_freq)
          b ofs len
        in
        b,0,Array.length b.(0)
      else
        b,ofs,len
    in
    let data =
    Ogg_encoder.Audio_data
     {
      Ogg_encoder.
       data   = buf;
       offset = ofs;
       length = len
     }
    in
    Ogg_encoder.encode encoder id data
  in
  encode

(** Helper to encode video. *)
let encode_video () =
  let encode encoder id frame ofs len =  
    let vid = VFrame.get_rgb frame in
    let vofs = Fmt.video_frames_of_ticks ofs in
    let vlen = Fmt.video_frames_of_ticks len in
    let data =
     Ogg_encoder.Video_data
      {
       Ogg_encoder.
        data    = vid;
        offset  = vofs;
        length  = vlen
      }
    in
    Ogg_encoder.encode encoder id data
  in
  encode

class virtual base streams = 
  let streams = 
    let f = 
      Hashtbl.create 2 
    in
    List.iter 
      (fun (x,(y,z)) -> Hashtbl.add f x (ref None,y,z))
      streams;
    f
  in
object(self)

  val virtual mutable encoder : Ogg_encoder.t option
  val streams : (string,ogg_track) Hashtbl.t = streams 

  method virtual id : string

  method create_encoders m =
    let enc = Utils.get_some encoder in 
    let create _ (sid,f,_) = 
      assert(!sid = None);
      sid := Some (f enc m) 
    in
    Hashtbl.iter create streams;
    Ogg_encoder.streams_start enc

  method reset_stream m = 
    let flushed = self#end_of_stream in
    let reset _ (id,_,_) = 
      id := None
    in
    Hashtbl.iter reset streams;
    self#create_encoders m;
    flushed

  method encode frame ofs len = 
    let enc = Utils.get_some encoder in
    if !(enc.Ogg_encoder.bos) then
      self#create_encoders [];
    let encode _ (id,_,f) = 
      let id = Utils.get_some !id in
      f enc id frame ofs len
    in
    Hashtbl.iter encode streams;
    Ogg_encoder.get_data enc

  method output_start = 
    encoder <- Some (Ogg_encoder.create self#id)

  method end_of_stream = 
    let enc = Utils.get_some encoder in
    Ogg_encoder.end_of_stream enc;
    Ogg_encoder.flush enc

  (** Ogg encoder must be stoped (and flushed)
    * before calling this function. *)
  method output_stop =
    let enc = Utils.get_some encoder in
    assert(!(enc.Ogg_encoder.eos));
    encoder <- None
end

(** Output in an Ogg file. *)
class to_file
  filename ~append ~perm ~dir_perm
  ~reload_delay ~reload_predicate ~reload_on_metadata
  ~autostart ~streams source =
object (self)
  inherit
    [Ogg_encoder.t] Output.encoded
      ~name:filename ~kind:"output.file" ~autostart source
  inherit File_output.to_file
            ~reload_delay ~reload_predicate ~reload_on_metadata
            ~append ~perm ~dir_perm filename as to_file
  inherit base streams as ogg

  method reset_encoder m =
    to_file#on_reset_encoder ;
    to_file#set_metadata (Hashtbl.find (Hashtbl.copy m)) ;
    let m = 
      let f x y z = 
        (x,y)::z
      in
      Hashtbl.fold f m []
    in
    ogg#reset_stream m

  method output_start =
    ogg#output_start;
    to_file#file_output_start

  method output_stop =
    let f = ogg#end_of_stream in
    ogg#output_stop;
    to_file#send f ;
    to_file#file_output_stop

end