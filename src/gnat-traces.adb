-----------------------------------------------------------------------
--                               G P S                               --
--                                                                   --
--                     Copyright (C) 2001-2007, AdaCore              --
--                                                                   --
-- GPS is free  software;  you can redistribute it and/or modify  it --
-- under the terms of the GNU General Public License as published by --
-- the Free Software Foundation; either version 2 of the License, or --
-- (at your option) any later version.                               --
--                                                                   --
-- This program is  distributed in the hope that it will be  useful, --
-- but  WITHOUT ANY WARRANTY;  without even the  implied warranty of --
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU --
-- General Public License for more details. You should have received --
-- a copy of the GNU General Public License along with this program; --
-- if not,  write to the  Free Software Foundation, Inc.,  59 Temple --
-- Place - Suite 330, Boston, MA 02111-1307, USA.                    --
-----------------------------------------------------------------------

with Ada.Calendar;              use Ada.Calendar;
with Ada.Characters.Handling;   use Ada.Characters.Handling;
with Ada.Strings.Fixed;         use Ada.Strings.Fixed;
with Ada.Text_IO;               use Ada.Text_IO;
with Ada.Unchecked_Deallocation;

with GNAT.Calendar;             use GNAT.Calendar;
with GNAT.Calendar.Time_IO;     use GNAT.Calendar.Time_IO;
with GNAT.Directory_Operations; use GNAT.Directory_Operations;
with GNAT.IO_Aux;               use GNAT.IO_Aux;
with GNAT.Mmap;                 use GNAT.Mmap;
with GNAT.OS_Lib;               use GNAT.OS_Lib;
with GNAT.Task_Lock;            use GNAT.Task_Lock;
with GNAT.Traceback;            use GNAT.Traceback;

with System.Address_Image;
with System.Assertions;         use System.Assertions;

package body GNAT.Traces is

   --  Note: rev 1.5 of this file has a (disabled) support for symbolic
   --  tracebacks.

   --  ??? We could display the stack pointer with
   --  procedure Print_Sp is
   --     start : aliased Integer;
   --  begin
   --     Put_Line (System.Address_Image (Start'Address));
   --  end;

   --  Red_Fg     : constant String := ASCII.ESC & "[31m";
   --  Green_Fg   : constant String := ASCII.ESC & "[32m";
   Brown_Fg   : constant String := ASCII.ESC & "[33m";
   --  Blue_Fg    : constant String := ASCII.ESC & "[34m";
   Purple_Fg  : constant String := ASCII.ESC & "[35m";
   Cyan_Fg    : constant String := ASCII.ESC & "[36m";
   --  Grey_Fg    : constant String := ASCII.ESC & "[37m";
   Default_Fg : constant String := ASCII.ESC & "[39m";

   Red_Bg     : constant String := ASCII.ESC & "[41m";
   --  Green_Bg   : constant String := ASCII.ESC & "[42m";
   --  Brown_Bg   : constant String := ASCII.ESC & "[43m";
   --  Blue_Bg    : constant String := ASCII.ESC & "[44m";
   --  Purple_Bg  : constant String := ASCII.ESC & "[45m";
   --  Cyan_Bg    : constant String := ASCII.ESC & "[46m";
   --  Grey_Bg    : constant String := ASCII.ESC & "[47m";
   Default_Bg : constant String := ASCII.ESC & "[49m";

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Trace_Handle_Record'Class, Trace_Handle);
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Trace_Stream_Record'Class, Trace_Stream);

   type Stream_Factories;
   type Stream_Factories_List is access Stream_Factories;
   type Stream_Factories is record
      Name          : GNAT.Strings.String_Access;
      Factory       : Stream_Factory_Access;
      Next          : Stream_Factories_List;
   end record;

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Stream_Factories, Stream_Factories_List);

   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (Stream_Factory'Class, Stream_Factory_Access);

   Handles_List : Trace_Handle := null;
   --  The global list of all defined handles.
   --  Accesses to this list are protected by calls to
   --  System.Soft_Links.Lock_Task (we do not use a protected type so that
   --  applications that do not use tasking otherwise do not drag the whole
   --  tasking runtime in).

   Streams_List : Trace_Stream := null;
   --  The global list of all streams. Accesses to this list are protected by
   --  calls to System.Soft_Links.Lock_Task.
   --  The default stream is the first in the list.

   Factories_List : Stream_Factories_List := null;
   --  The global list of all factories. Access to this list are protected by
   --  calls to Lock_Task

   Default_Activation : Boolean := False;
   --  Default activation status for debug handles (ie whether the
   --  configuration file contained "+").

   Indentation : Natural := 0;

   function Find_Handle (Unit_Name_Upper_Case : String) return Trace_Handle;
   --  Return the debug handle associated with Unit_Name_Upper_Case,
   --  or null if there is none. The case of Unit_Name_Upper_Case is
   --  not changed.
   --  Note: this subprogram doesn't do any locking, it is the
   --  responsability of the called to make sure that not two tasks
   --  can access it at the same time.

   function Find_Stream
     (Stream_Name      : String;
      Config_File_Name : String) return Trace_Stream;
   --  Return the stream associated with that name (either an existing one or
   --  one created by a factory), or null if the default stream should be
   --  applied. This program doesn't do any locking, and must be called from
   --  withing appropriately locked code.

   procedure Log
     (Handle        : Trace_Handle;
      Message       : String;
      Location      : String := GNAT.Source_Info.Source_Location;
      Entity        : String := GNAT.Source_Info.Enclosing_Entity;
      Message_Color : String := Default_Fg);
   --  Log a message to Handle unconditionally.

   procedure Put_Absolute_Time (Stream : in out Trace_Stream_Record'Class);
   --  Print the absolute time in Handle. No locking is done, this is the
   --  responsability of the caller. No colors is modified either.

   procedure Put_Elapsed_Time
     (Handle : in out Trace_Handle_Record'Class;
      Stream : in out Trace_Stream_Record'Class);
   --  Print the elapsed time the last call to Trace for this Handle. No
   --  locking done.

   procedure Put_Stack_Trace (Stream : in out Trace_Stream_Record'Class);
   --  Print the stack trace for this handle. No locking done.

   function Config_File
     (Filename : String;
      Default  : String) return String;
   --  Return the name of the config file to use.
   --  If Filename is specified, this is the file to use, providing it exists.
   --  Otherwise, we use a .gnatdebug in the current directory, and if there is
   --  none, Default if it exists.
   --  The empty string is returned if no such file was found.

   function Get_Process_Id return Integer;
   --  Return the process ID of the current process.
   pragma Import (C, Get_Process_Id, "getpid");

   type File_Type_Access is access all File_Type;
   procedure Unchecked_Free is new Ada.Unchecked_Deallocation
     (File_Type, File_Type_Access);

   type File_Stream_Record is new Trace_Stream_Record with record
      File : File_Type_Access;
   end record;
   overriding procedure Put (Stream : in out File_Stream_Record; Str : String);
   overriding procedure Newline (Stream : in out File_Stream_Record);
   overriding procedure Close (Stream : in out File_Stream_Record);
   --  Logs to a file

   type Stdout_Stream_Record is new Trace_Stream_Record with null record;
   overriding procedure Put
     (Stream : in out Stdout_Stream_Record; Str : String);
   overriding procedure Newline (Stream : in out Stdout_Stream_Record);
   --  Logs to stdout

   type Stderr_Stream_Record is new Trace_Stream_Record with null record;
   overriding procedure Put
     (Stream : in out Stderr_Stream_Record; Str : String);
   overriding procedure Newline (Stream : in out Stderr_Stream_Record);
   --  Logs to stderr

   -----------------
   -- Find_Handle --
   -----------------

   function Find_Handle (Unit_Name_Upper_Case : String) return Trace_Handle is
      Tmp : Trace_Handle := Handles_List;
   begin
      while Tmp /= null
        and then Tmp.Name.all /= Unit_Name_Upper_Case
      loop
         Tmp := Tmp.Next;
      end loop;
      return Tmp;
   end Find_Handle;

   ------------------------
   -- Show_Configuration --
   ------------------------

   procedure Show_Configuration (Output : Output_Proc) is
      Tmp : Trace_Handle := Handles_List;
   begin
      while Tmp /= null loop
         if Tmp.Stream /= null then
            if Tmp.Active then
               Output (Tmp.Name.all & "=yes >" & Tmp.Stream.Name.all);
            else
               Output (Tmp.Name.all & "=no >" & Tmp.Stream.Name.all);
            end if;
         else
            if Tmp.Active then
               Output (Tmp.Name.all & "=yes");
            else
               Output (Tmp.Name.all & "=no");
            end if;
         end if;
         Tmp := Tmp.Next;
      end loop;
   end Show_Configuration;

   -----------------
   -- Find_Stream --
   -----------------

   function Find_Stream
     (Stream_Name      : String;
      Config_File_Name : String) return Trace_Stream
   is
      procedure Add_To_Streams (Tmp : Trace_Stream);

      procedure Add_To_Streams (Tmp : Trace_Stream) is
      begin
         --  If possible, do not put this first on the list of streams,
         --  since it would become the default stream
         if Streams_List = null then
            Streams_List := Tmp;
            Tmp.Next := null;
         else
            Tmp.Next := Streams_List.Next;
            Streams_List.Next := Tmp;
         end if;
      end Add_To_Streams;

      Name  : constant String := Trim (Stream_Name, Ada.Strings.Both);

      Tmp   : Trace_Stream;
      Colon : Natural;
      TmpF  : Stream_Factories_List;

   begin
      if Name = "" then
         return null;
      end if;

      Lock;

      --  Do we have a matching existing stream ?

      Tmp := Streams_List;
      while Tmp /= null loop
         if Tmp.Name.all = Name then
            Unlock;
            return Tmp;
         end if;
         Tmp := Tmp.Next;
      end loop;

      Colon := Index (Name, ":");
      if Colon < Name'First then
         Colon := Name'Last + 1;
      end if;

      --  Do we have a matching factory (if we start with "&")?

      if Name = "&1" then
         Tmp := new Stdout_Stream_Record'
           (Name => new String'(Name),
            Next => null);
         Add_To_Streams (Tmp);

      elsif Name = "&2" then
         Tmp := new Stderr_Stream_Record'
           (Name => new String'(Name),
            Next => null);
         Add_To_Streams (Tmp);

      elsif Name (Name'First) = '&' then
         Tmp := null;
         TmpF := Factories_List;
         while TmpF /= null loop
            if TmpF.Name.all = Name (Name'First .. Colon - 1) then
               if Colon < Name'Last then
                  Tmp := TmpF.Factory.New_Stream
                    (Name (Colon + 1 .. Name'Last));
               else
                  Tmp := TmpF.Factory.New_Stream ("");
               end if;

               Tmp.Name := new String'(Name);
               Add_To_Streams (Tmp);
               exit;
            end if;

            TmpF := TmpF.Next;
         end loop;

      else
         Tmp := new File_Stream_Record'
           (Name => new String'(Name),
            Next => null,
            File => new File_Type);

         declare
            Max_Date_Width : constant Natural := 10; --  "yyyy-mm-dd"
            Max_PID_Width  : constant Natural := 12;
            Max_Name_Last : constant Natural :=
              Name'Last + Max_Date_Width + Max_PID_Width;
            Name_Tmp : String (Name'First .. Max_Name_Last);
            Index : Integer := Name_Tmp'First;
            N     : Integer := Name'First;
         begin
            while N <= Name'Last loop
               if Name (N) = '$' then
                  if N < Name'Last
                    and then Name (N + 1) = '$'
                  then
                     declare
                        Pid : constant String :=
                          Integer'Image (Get_Process_Id);
                     begin
                        Name_Tmp (Index .. Index + Pid'Length - 2) :=
                          Pid (Pid'First + 1 .. Pid'Last);
                        Index := Index + Pid'Length - 1;
                        N     := N + 1;
                     end;

                  elsif N < Name'Last
                    and then Name (N + 1) = 'D'
                  then
                     declare
                        Date : constant String := Image
                          (Clock, "%Y-%m-%d");
                     begin
                        Name_Tmp (Index .. Index + Date'Length - 1) := Date;
                        Index := Index + Date'Length;
                        N     := N + 1;
                     end;

                  else
                     Name_Tmp (Index) := Name (N);
                     Index := Index + 1;
                  end if;

               else
                  Name_Tmp (Index) := Name (N);
                  Index := Index + 1;
               end if;

               N := N + 1;
            end loop;

            Create
              (File_Stream_Record (Tmp.all).File.all, Out_File,
               Normalize_Pathname
                 (Name_Tmp (Name_Tmp'First .. Index - 1),
                  Dir_Name (Config_File_Name)));

            Add_To_Streams (Tmp);
         end;
      end if;

      --  Else use the default stream

      Unlock;
      return Tmp;
   end Find_Stream;

   ------------
   -- Create --
   ------------

   function Create
     (Unit_Name : String;
      Default   : Default_Activation_Status := From_Config;
      Stream    : String := "";
      Factory   : Handle_Factory := null;
      Finalize  : Boolean := True) return Trace_Handle
   is
      Tmp        : Trace_Handle    := null;
      Upper_Case : constant String := To_Upper (Unit_Name);
   begin
      if Debug_Mode then
         Lock;

         Tmp := Find_Handle (Upper_Case);
         if Tmp = null then
            if Factory /= null then
               Tmp := Factory.all;
            end if;

            if Tmp = null then
               Tmp := new Trace_Handle_Record;
            end if;

            Tmp.Name          := new String'(Upper_Case);
            Tmp.Active        := Default_Activation;
            Tmp.Forced_Active := False;
            Tmp.Stream        := null;
            Tmp.Timer         := Ada.Calendar.Clock;
            Tmp.Count         := 1;
            Tmp.Next          := Handles_List;
            Tmp.Finalize      := Finalize;
            Handles_List := Tmp;
         end if;

         if Tmp.Stream = null then
            Tmp.Stream := Find_Stream (Stream, "");
         end if;

         if not Tmp.Forced_Active then
            if Default = On then
               Tmp.Active := True;
               Tmp.Forced_Active := True;
            elsif Default = Off then
               Tmp.Active := False;
               Tmp.Forced_Active := True;
            end if;
         end if;

         Unlock;
      end if;
      return Tmp;
   exception
      when others =>
         Unlock;
         raise;
   end Create;

   ------------------------
   -- Predefined handles --
   ------------------------
   --  This must be done after the body of Create has been seen

   Absolute_Time    : constant Trace_Handle := Create ("DEBUG.ABSOLUTE_TIME");
   Absolute_Date    : constant Trace_Handle :=
     Create ("DEBUG.ABSOLUTE_DATE", Off);
   Elapsed_Time     : constant Trace_Handle := Create ("DEBUG.ELAPSED_TIME");
   Stack_Trace      : constant Trace_Handle := Create ("DEBUG.STACK_TRACE");
   Colors           : constant Trace_Handle := Create ("DEBUG.COLORS");
   Enclosing_Entity : constant Trace_Handle :=
     Create ("DEBUG.ENCLOSING_ENTITY");
   Location         : constant Trace_Handle := Create ("DEBUG.LOCATION");
   Count            : constant Trace_Handle := Create ("DEBUG.COUNT");
   Finalize_Traces  : constant Trace_Handle :=
     Create ("DEBUG.FINALIZE_TRACES", On);
   --  If set to Off, this module will not be finalized, and traces will still
   --  be activated when the program itself is finalized by GNAT

   ---------------
   -- Unit_Name --
   ---------------

   function Unit_Name (Handle : Trace_Handle) return String is
   begin
      return Handle.Name.all;
   end Unit_Name;

   -----------
   -- Trace --
   -----------

   procedure Trace
     (Handle : Trace_Handle;
      E      : Ada.Exceptions.Exception_Occurrence;
      Msg    : String := "Unexpected exception: ") is
   begin
      Trace (Handle, Msg & Ada.Exceptions.Exception_Information (E));
   end Trace;

   -----------
   -- Trace --
   -----------

   procedure Trace
     (Handle   : Trace_Handle;
      Message  : String;
      Location : String := GNAT.Source_Info.Source_Location;
      Entity   : String := GNAT.Source_Info.Enclosing_Entity) is
   begin
      if Debug_Mode
        and then Handles_List /= null  --  module not terminated
        and then Handle.Active
      then
         Log (Handle, Message, Location, Entity);
      end if;
   end Trace;

   ------------
   -- Assert --
   ------------

   procedure Assert
     (Handle             : Trace_Handle;
      Condition          : Boolean;
      Error_Message      : String;
      Message_If_Success : String := "";
      Raise_Exception    : Boolean := True;
      Location           : String := GNAT.Source_Info.Source_Location;
      Entity             : String := GNAT.Source_Info.Enclosing_Entity) is
   begin
      if Debug_Mode and then Handles_List /= null and then Handle.Active then
         if not Condition then
            Log (Handle, Error_Message, Location, Entity, Red_Bg & Default_Fg);

            if Raise_Exception then
               Raise_Assert_Failure
                 (Error_Message & " (" & Entity & " at " &
                  Location & ")");
            end if;

         elsif Message_If_Success'Length /= 0 then
            Log (Handle, Message_If_Success, Location, Entity);
         end if;
      end if;
   end Assert;

   ---------------------
   -- Increase_Indent --
   ---------------------

   procedure Increase_Indent
     (Handle : Trace_Handle := null; Msg : String := "")
   is
   begin
      if Handle /= null and then Msg /= "" then
         Trace (Handle, Msg);
      end if;
      Indentation := Indentation + 1;
   end Increase_Indent;

   ---------------------
   -- Decrease_Indent --
   ---------------------

   procedure Decrease_Indent
     (Handle : Trace_Handle := null; Msg : String := "") is
   begin
      if Indentation > 0 then
         Indentation := Indentation - 1;
         if Handle /= null and then Msg /= "" then
            Trace (Handle, Msg);
         end if;
      else
         if Handle /= null then
            Trace (Handle, "Indentation error: two many decrease");
            if Msg /= "" then
               Trace (Handle, Msg);
            end if;
         end if;
      end if;
   end Decrease_Indent;

   ----------------
   -- Set_Active --
   ----------------

   procedure Set_Active (Handle : Trace_Handle; Active : Boolean) is
   begin
      Handle.Active := Active;
   end Set_Active;

   ------------
   -- Active --
   ------------

   function Active (Handle : Trace_Handle) return Boolean is
   begin
      if Handles_List = null then
         --  If this module has been finalized, we always display the traces.
         --  These traces are generally when GNAT finalizes controlled types...
         return True;

      elsif Handle = null then
         --  In case Handle hasn't been initialized yet
         return False;

      else
         return Handle.Active;
      end if;
   end Active;

   -----------------------
   -- Put_Absolute_Time --
   -----------------------

   procedure Put_Absolute_Time (Stream : in out Trace_Stream_Record'Class) is
      T  : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Ms : constant String := Integer'Image (Integer (Sub_Second (T) * 1000));
   begin
      if Absolute_Date.Active then
         if Absolute_Time.Active then
            Put (Stream, "(" & Image (T, ISO_Date & " %T.")
                 & Ms (Ms'First + 1 .. Ms'Last) & ')');
         else
            Put (Stream, "(" & Image (T, ISO_Date) & ')');
         end if;
      else
         Put (Stream, "(" & Image (T, "%T.")
              & Ms (Ms'First + 1 .. Ms'Last) & ')');
      end if;
   end Put_Absolute_Time;

   ----------------------
   -- Put_Elapsed_Time --
   ----------------------

   procedure Put_Elapsed_Time
     (Handle : in out Trace_Handle_Record'Class;
      Stream : in out Trace_Stream_Record'Class)
   is
      T   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
      Dur : Integer;
   begin
      Dur := Integer ((T - Handle.Timer) * 1000);
      Put (Stream, "(elapsed:" & Integer'Image (Dur) & "ms)");
      Handle.Timer := T;
   end Put_Elapsed_Time;

   ---------------------
   -- Put_Stack_Trace --
   ---------------------

   procedure Put_Stack_Trace (Stream : in out Trace_Stream_Record'Class) is
      Tracebacks : Tracebacks_Array (1 .. 50);
      Len        : Natural;
   begin
      Call_Chain (Tracebacks, Len);
      Put (Stream, "(callstack: ");
      for J in Tracebacks'First .. Len loop
         Put (Stream, System.Address_Image (Tracebacks (J)) & ' ');
      end loop;
      Put (Stream, ")");
   end Put_Stack_Trace;

   -------------------
   -- Pre_Decorator --
   -------------------

   procedure Pre_Decorator
     (Handle  : in out Trace_Handle_Record;
      Stream  : in out Trace_Stream_Record'Class;
      Message : String)
   is
      pragma Unreferenced (Message);
   begin
      if Count.Active then
         declare
            C : constant String := Integer'Image (Count.Count);
            H : constant String := Integer'Image (Handle.Count);
         begin
            Put (Stream, H (H'First + 1 .. H'Last)
                 & '/' & C (C'First + 1 .. C'Last) & ' ');
         end;
         Count.Count := Count.Count + 1;
         Handle.Count := Handle.Count + 1;
      end if;
   end Pre_Decorator;

   --------------------
   -- Post_Decorator --
   --------------------

   procedure Post_Decorator
     (Handle   : in out Trace_Handle_Record;
      Stream   : in out Trace_Stream_Record'Class;
      Location : String;
      Entity   : String;
      Message  : String)
   is
      pragma Unreferenced (Message);

      Space_Inserted : Boolean := False;
      --  True when a space has been inserted after the main trace text, before
      --  the Post_Decorator information.

      procedure Ensure_Space;
      --  Insert a space if not done already

      procedure Ensure_Space is
      begin
         if not Space_Inserted then
            Put (Stream, " ");
            Space_Inserted := True;
         end if;
      end Ensure_Space;

   begin
      if (Absolute_Time.Active or else Absolute_Date.Active)
        and then Supports_Time (Stream)
      then
         Ensure_Space;
         Put_Absolute_Time (Stream);
      end if;

      if Elapsed_Time.Active then
         Ensure_Space;
         Put_Elapsed_Time (Handle, Stream);
      end if;

      if Traces.Location.Active then
         Ensure_Space;
         Put (Stream, "(loc: " & Location & ')');
      end if;

      if Enclosing_Entity.Active then
         Ensure_Space;
         Put (Stream, "(entity:" & Entity & ')');
      end if;

      if Stack_Trace.Active then
         Ensure_Space;
         Put_Stack_Trace (Stream);
      end if;
   end Post_Decorator;

   ---------
   -- Log --
   ---------

   procedure Log
     (Handle        : Trace_Handle;
      Message       : String;
      Location      : String := GNAT.Source_Info.Source_Location;
      Entity        : String := GNAT.Source_Info.Enclosing_Entity;
      Message_Color : String := Default_Fg)
   is
      Start, Last  : Positive;
      Continuation : constant String := '_' & Handle.Name.all & "_ ";
      Stream       : Trace_Stream;
      Color        : Boolean;
   begin
      if Message'Length = 0 then
         return;
      end if;

      if Handle.Stream /= null then
         Stream := Handle.Stream;
      else
         Stream := Streams_List;
      end if;

      if Stream = null then
         return;
      end if;

      Color := Colors.Active and then Supports_Color (Stream.all);

      Lock;

      if Indentation > 0 then
         Put (Stream.all, String'(1 .. Indentation * 3 => ' '));
      end if;

      if Color then
         Put (Stream.all, Cyan_Fg);
      end if;

      Put (Stream.all, '[' & Handle.Name.all & "] ");
      Pre_Decorator (Handle.all, Stream.all, Message);

      if Color then
         Put (Stream.all, Message_Color);
      end if;

      Start := Message'First;
      loop
         Last := Start;
         while Last <= Message'Last
           and then Message (Last) /= ASCII.LF
           and then Message (Last) /= ASCII.CR
         loop
            Last := Last + 1;
         end loop;

         Put (Stream.all, Message (Start .. Last - 1));

         Start := Last + 1;
         exit when Start > Message'Last;

         Newline (Stream.all);
         if Color then
            Put (Stream.all, Purple_Fg & Default_Bg);
         end if;
         Put (Stream.all, Continuation);
         if Color then
            Put (Stream.all, Message_Color);
         end if;
      end loop;

      if Color then
         Put (Stream.all, Brown_Fg & Default_Bg);
      end if;

      Post_Decorator (Handle.all, Stream.all, Message, Location, Entity);

      if Color then
         Put (Stream.all, Default_Fg);
      end if;

      Newline (Stream.all);

      Unlock;

   exception
      when others =>
         Unlock;
         raise;
   end Log;

   -----------------
   -- Config_File --
   -----------------

   function Config_File
     (Filename : String;
      Default  : String) return String
   is
      Env  : GNAT.Strings.String_Access := Getenv (Config_File_Environment);
      Home : GNAT.Strings.String_Access;
   begin
      if Filename /= "" and then File_Exists (Filename) then
         GNAT.Strings.Free (Env);
         return Filename;
      end if;

      --  First test the file described in the environment variable
      if Env /= null and then Env.all /= "" then
         if File_Exists (Env.all) then
            declare
               N : constant String := Env.all;
            begin
               Free (Env);
               return N;
            end;
         end if;

         Free (Env);
         return "";
      end if;

      Free (Env);

      --  Then the file in the current directory

      if File_Exists (Default_Config_File) then
         return Default_Config_File;
      end if;

      --  Then the file in the user's home directory
      Home := Getenv ("HOME");

      if Home /= null and then Home.all /= "" then
         declare
            N : constant String :=
              Format_Pathname (Home.all & '/' & Default_Config_File);
         begin
            Free (Home);

            if File_Exists (N) then
               return N;
            end if;
         end;
      end if;

      Free (Home);

      --  Finally the default file
      if Default /= "" and then File_Exists (Default) then
         return Default;
      end if;

      return "";
   end Config_File;

   -----------------------------
   -- Register_Stream_Factory --
   -----------------------------

   procedure Register_Stream_Factory
     (Name : String; Factory : Stream_Factory_Access)
   is
   begin
      Lock;
      Factories_List := new Stream_Factories'
        (Name    => new String'("&" & Name),
         Factory => Factory,
         Next    => Factories_List);
      Unlock;
   end Register_Stream_Factory;

   --------------------
   -- Supports_Color --
   --------------------

   function Supports_Color (Stream : Trace_Stream_Record) return Boolean is
      pragma Unreferenced (Stream);
   begin
      return True;
   end Supports_Color;

   -------------------
   -- Supports_Time --
   -------------------

   function Supports_Time (Stream : Trace_Stream_Record) return Boolean is
      pragma Unreferenced (Stream);
   begin
      return True;
   end Supports_Time;

   -----------
   -- Close --
   -----------

   procedure Close (Stream : in out Trace_Stream_Record) is
   begin
      Free (Stream.Name);
   end Close;

   ---------
   -- Put --
   ---------

   procedure Put (Stream : in out Stdout_Stream_Record; Str : String) is
      pragma Unreferenced (Stream);
   begin
      Put (Str);
   end Put;

   -------------
   -- Newline --
   -------------

   procedure Newline (Stream : in out Stdout_Stream_Record) is
      pragma Unreferenced (Stream);
   begin
      New_Line;
      Flush;
   end Newline;

   ---------
   -- Put --
   ---------

   procedure Put (Stream : in out Stderr_Stream_Record; Str : String) is
      pragma Unreferenced (Stream);
   begin
      Put (Ada.Text_IO.Standard_Error, Str);
   end Put;

   -------------
   -- Newline --
   -------------

   procedure Newline (Stream : in out Stderr_Stream_Record) is
      pragma Unreferenced (Stream);
   begin
      New_Line (Ada.Text_IO.Standard_Error);
      Flush (Ada.Text_IO.Standard_Error);
   end Newline;

   ---------
   -- Put --
   ---------

   procedure Put (Stream : in out File_Stream_Record; Str : String) is
   begin
      if Stream.File /= null then
         Put (Stream.File.all, Str);
      end if;
   end Put;

   -------------
   -- Newline --
   -------------

   procedure Newline (Stream : in out File_Stream_Record) is
   begin
      if Stream.File /= null then
         New_Line (Stream.File.all);
         Flush (Stream.File.all);
      end if;
   end Newline;

   -----------
   -- Close --
   -----------

   procedure Close (Stream : in out File_Stream_Record) is
   begin
      Close (Stream.File.all);
      Unchecked_Free (Stream.File);
   end Close;

   -----------------------
   -- Parse_Config_File --
   -----------------------

   procedure Parse_Config_File
     (Filename : String := "";
      Default  : String := "")
   is
      File_Name  : aliased constant String := Config_File (Filename, Default);
      Buffer     : Str_Access;
      File       : Mapped_File;
      Index, First, Max : Natural;
      Handle     : Trace_Handle;

      procedure Skip_Spaces (Skip_Newline : Boolean := True);
      --  Skip the spaces (including possibly newline), and leave Index on the
      --  first non blank character.

      procedure Skip_To_Newline (Stop_At_First_Blank : Boolean := False);
      --  Set Index after the last significant character on the line (either
      --  the ASCII.LF or after the last character in the buffer).

      -----------------
      -- Skip_Spaces --
      -----------------

      procedure Skip_Spaces (Skip_Newline : Boolean := True) is
      begin
         while Index <= Last (File)
           and then (Buffer (Index) = ' '
                     or else (Buffer (Index) = ASCII.LF
                              and then Skip_Newline)
                     or else Buffer (Index) = ASCII.CR
                     or else Buffer (Index) = ASCII.HT)
         loop
            Index := Index + 1;
         end loop;
      end Skip_Spaces;

      ---------------------
      -- Skip_To_Newline --
      ---------------------

      procedure Skip_To_Newline (Stop_At_First_Blank : Boolean := False) is
      begin
         while Index <= Last (File)
           and then Buffer (Index) /= ASCII.LF
           and then (not Stop_At_First_Blank
                     or else (Buffer (Index) /= ' '
                              and then Buffer (Index) /= ASCII.HT))
         loop
            Index := Index + 1;
         end loop;
      end Skip_To_Newline;

   begin
      if File_Name /= "" then
         begin
            File := Open_Read (File_Name);
         exception
            when Name_Error =>
               return;
         end;

         Lock;
         Read (File);
         Buffer := Data (File);

         Index := 1;

         loop
            Skip_Spaces;
            exit when Index > Last (File);

            if Index + 1 <= Last (File)
              and then String (Buffer (Index .. Index + 1)) = "--"
            then
               Skip_To_Newline;

            else
               case Buffer (Index) is
                  when '>' =>
                     declare
                        Save   : constant Integer := Index + 1;
                        Stream : Trace_Stream;
                        Tmp    : Trace_Stream;
                     begin
                        Skip_To_Newline;
                        if Buffer (Index - 1) = ASCII.CR then
                           Stream := Find_Stream
                             (String (Buffer (Save .. Index - 2)), File_Name);
                        else
                           Stream := Find_Stream
                             (String (Buffer (Save .. Index - 1)), File_Name);
                        end if;
                        if Stream /= null then
                           --  Put this first in the list, since that's the
                           --  default
                           if Streams_List /= Stream then
                              Tmp := Streams_List;
                              while Tmp /= null
                                and then Tmp.Next /= Stream
                              loop
                                 Tmp := Tmp.Next;
                              end loop;

                              if Tmp /= null then
                                 Tmp.Next := Stream.Next;
                                 Stream.Next := Streams_List;
                                 Streams_List := Stream;
                              end if;
                           end if;
                        end if;
                     end;

                  when '+' =>
                     Default_Activation := True;
                     Skip_To_Newline;
                     Handle := Handles_List;
                     while Handle /= null loop
                        if not Handle.Forced_Active
                          and then Handle /= Absolute_Time
                          and then Handle /= Elapsed_Time
                          and then Handle /= Stack_Trace
                          and then Handle /= Colors
                          and then Handle /= Enclosing_Entity
                          and then Handle /= Location
                        then
                           Handle.Active := True;
                        end if;
                        Handle := Handle.Next;
                     end loop;

                  when others =>
                     First := Index;
                     while Index <= Last (File)
                       and then Buffer (Index) /= '='
                       and then Buffer (Index) /= '>'
                       and then Buffer (Index) /= '-'
                       and then Buffer (Index) /= ASCII.LF
                       and then Buffer (Index) /= ASCII.CR
                     loop
                        Index := Index + 1;
                     end loop;

                     Max := Index - 1;
                     while Max >= 1
                       and then (Buffer (Max) = ' '
                                 or else Buffer (Max) = ASCII.HT)
                     loop
                        Max := Max - 1;
                     end loop;

                     Handle := Create (String (Buffer (First .. Max)));

                     if Index > Last (File)
                       or else Buffer (Index) /= '='
                     then
                        Handle.Active := True;
                     else
                        Index := Index + 1;
                        Skip_Spaces;
                        Handle.Active :=
                          Index + 1 > Last (File)
                          or else String (Buffer (Index .. Index + 1)) /= "no";
                     end if;

                     while Index <= Last (File)
                       and then Buffer (Index) /= '>'
                       and then Buffer (Index) /= ASCII.LF
                       and then Buffer (Index) /= ASCII.CR
                     loop
                        Index := Index + 1;
                     end loop;

                     if Index <= Last (File)
                       and then Buffer (Index) = '>'
                     then
                        declare
                           Save : constant Integer := Index + 1;
                        begin
                           Skip_To_Newline;
                           if Buffer (Index - 1) = ASCII.CR then
                              Handle.Stream := Find_Stream
                                (String (Buffer (Save .. Index - 2)),
                                 File_Name);
                           else
                              Handle.Stream := Find_Stream
                                (String (Buffer (Save .. Index - 1)),
                                 File_Name);
                           end if;
                        end;
                     else
                        Skip_To_Newline;
                     end if;

               end case;
            end if;
         end loop;

         Close (File);
         Unlock;
      end if;

   exception
      when others =>
         Unlock;
         raise;
   end Parse_Config_File;

   --------------
   -- Finalize --
   --------------

   procedure Finalize is
      Tmp   : Trace_Handle;
      Next  : Trace_Handle;
      TmpS  : Trace_Stream;
      NextS : Trace_Stream;
      TmpF  : Stream_Factories_List;
      NextF : Stream_Factories_List;
   begin
      if Active (Finalize_Traces) then
         Lock;
         Tmp := Handles_List;
         while Tmp /= null loop
            Next := Tmp.Next;

            if Tmp.Finalize then
               Free (Tmp.Name);
               Unchecked_Free (Tmp);
            end if;

            Tmp := Next;
         end loop;
         Handles_List := null;

         TmpS := Streams_List;
         while TmpS /= null loop
            NextS := TmpS.Next;
            Close (TmpS.all);
            Unchecked_Free (TmpS);
            TmpS := NextS;
         end loop;
         Streams_List := null;

         TmpF := Factories_List;
         while TmpF /= null loop
            NextF := TmpF.Next;
            Free (TmpF.Name);
            Unchecked_Free (TmpF.Factory);
            Unchecked_Free (TmpF);
            TmpF := NextF;
         end loop;
         Factories_List := null;

         Unlock;
      end if;
   end Finalize;

begin
   --  This is the default stream, always register it
   declare
      S : constant Trace_Stream := Find_Stream ("&1", "");
      pragma Unreferenced (S);
   begin
      null;
   end;
end GNAT.Traces;
