#include "Timer.h"

#include "PubSub.h"

#include "SensorRead.nc"

#include "Communication.nc"

#include <stdlib.h>

#include <time.h>

module PubSubC @safe() {
  uses {

    /****** INTERFACES *****/
    interface Boot;

    //interfaces for communication
    interface Packet;
    interface SplitControl as AMControl;
    interface Receive;
    interface AMSend;

    //interface for timers
    interface Timer < TMilli > as Timer0;
    interface Timer < TMilli > as Timer1;
    //other interfaces, if needed
  }
}
implementation {

  message_t packet;

  // Variables to store the message to send
  message_t queued_packet;
  uint16_t queue_addr;

  message_t messageQueue[MAX_QUEUE_SIZE]; // Message queue
  uint16_t addressQueue[MAX_QUEUE_SIZE]; // Address queue
  uint16_t queueSize = 0;

  // Radio Busy Flag
  bool locked;

  CommunicationNetwork networkTable;

  bool actual_send(uint16_t address, message_t * packet);
  bool generate_send(uint16_t address, message_t * packet, uint8_t type);

  uint16_t generateRandomDelay(uint16_t minDelay, uint16_t maxDelay);

  bool generate_send(uint16_t address, message_t * packet, uint8_t type) {
    /*
     * 
     * Function to be used when performing the send after the receive message event.
     * It store the packet and address into a global queue and start the timer execution to schedule the send.
     *
     */
    if (queueSize >= MAX_QUEUE_SIZE) {
      dbgerror("radio_send", "Message queue is full\n");
      return FALSE;
    }

    // Add the message to the queue
    messageQueue[queueSize] = * packet;
    addressQueue[queueSize] = address;
    queueSize++;

    if (call Timer0.isRunning()) {

      // Timer is already running, the message will be sent later
      dbg("radio_send", "Timer is already running, the message will be sent later\n");

    } else {

      // Timer is not running, start it
      call Timer0.startOneShot(generateRandomDelay(MIN_DELAY, MAX_DELAY));
    }
    return TRUE;
  }

  event void Timer0.fired() {
    /*
     * Timer triggered to perform the send.
     */
    if (queueSize > 0) {
      actual_send(addressQueue[0], & messageQueue[0]);
    }
  }

  bool actual_send(uint16_t address, message_t * packet) {
    /*
     * Logic to perform the actual send of the packet using the tinyOS interfaces
     */

    pubsub_message_t * payload = (pubsub_message_t * ) call Packet.getPayload(packet, sizeof(pubsub_message_t));

    if (locked) {
      dbgerror("radio_send", "Radio is locked\n");
      return FALSE;
    }

    switch (payload -> messageType) {

    case CONNECT:
      if (call AMSend.send(address, packet, sizeof(pubsub_message_t)) == SUCCESS) {
        locked = TRUE;
        dbg("radio_send", "Node %hu Sent a CONNECT message to PANC\n", TOS_NODE_ID);
        return TRUE;
      } else {
        dbgerror("radio_send", "Node %hu Failed to send a CONNECT message to PANC\n", TOS_NODE_ID);
        return FALSE;
      }
      break;

    case CONNECT_ACK:
      if (call AMSend.send(address, packet, sizeof(pubsub_message_t)) == SUCCESS) {
        locked = TRUE;
        dbg("radio_send", "Node %hu Sent a CONNECT_ACK message to Node %hu\n", TOS_NODE_ID, address);
        return TRUE;
      } else {
        dbgerror("radio_send", "Node %hu Failed to send a CONNECT_ACK message to Node %hu\n", TOS_NODE_ID, address);
        return FALSE;
      }
      break;

    default:
      dbgerror("radio_send", "Trying to send an invalid message type\n");
      return FALSE;
      break;
    }

  }

  event void Boot.booted() {
    dbg("boot", "Application booted.\n");
    // Start the radio
    call AMControl.start();
  }

  event void AMControl.startDone(error_t err) {
    // Radio startup done
    if (err == SUCCESS) {
      dbg("radio", "Radio started.\n");
      // Start the timer after the radio has started up successfully
      // start the timer if not PANC
      if (TOS_NODE_ID != 1) {
        call Timer1.startPeriodic(CONNECT_TIMEOUT);
      } else {
        // Initialize the CommunicationNetwork
        initializeCommunicationNetwork( & networkTable);
      }
    } else {
      // Radio startup failed
      dbg("radio", "Radio failed to start. Trying Againg...\n");
      // Try to start the radio again
      call AMControl.start();
    }

  }

  event void AMControl.stopDone(error_t err) {
    dbg("radio", "Radio stopped.\n");
  }

  event void Timer1.fired() {
    /*
     * Logic to trigger the Nodes to send CONNECT packets
     */

    dbg("timer", "Timer1 fired.\n");
    if (TOS_NODE_ID != 1) {
      pubsub_message_t * payload = (pubsub_message_t * ) call Packet.getPayload( & packet, sizeof(pubsub_message_t));
      if (payload == NULL) {
        // Failed to obtain payload pointer
        dbgerror("radio_pack", "Failed to obtain payload\n");
      } else {
        payload -> messageType = 0;
        payload -> nodeID = TOS_NODE_ID;

        // Generate and schedule the message transmission
        if (!generate_send(1, & packet, payload -> messageType)) {
          // Failed to schedule the message transmission, handle the error
          dbgerror("radio_send", "Failed to schedule message transmission\n");
        } else {
          dbg("radio_send", "Node %hu Scheduled a CONNECT message to PANC\n", TOS_NODE_ID);
        }
      }
    }

  }

  event message_t * Receive.receive(message_t * bufPtr, void * payload, uint8_t len) {
    /*
     * Parse the receive packet.
     * Implement all the functionalities
     * Perform the packet send using the generate_send function if needed
     */

    if (len != sizeof(pubsub_message_t)) {
      return bufPtr;
    } else {
      pubsub_message_t * receivedMsg = (pubsub_message_t * ) payload;
      dbg("radio_rec", "Received packet at time %s\n", sim_time_string());

      switch (receivedMsg -> messageType) {

      case CONNECT:
        dbg("radio_rec", "Received a CONNECT message from node %hu\n", receivedMsg -> nodeID);
        if (TOS_NODE_ID == 1) {
          // If the node is the PAN Coordinator, send a CONNECT_ACK message
          pubsub_message_t * payload = (pubsub_message_t * ) call Packet.getPayload( & packet, sizeof(pubsub_message_t));
          if (payload == NULL) {
            // Failed to obtain payload pointer
            dbgerror("radio_pack", "Failed to obtain payload\n");
          } else {
            uint16_t address = receivedMsg -> nodeID;

            // check if node is connected
            if (isConnected( & networkTable, address)) {
              dbg("radio_rec", "Node %hu is already connected to PANC\n", address);
            } else {
              // add node to the list of connected nodes
              if (addConnection( & networkTable, address)) {
                dbg("radio_rec", "Node %hu added to the list of connected nodes\n", address);
              }
            }

            payload -> messageType = CONNECT_ACK;
            payload -> nodeID = TOS_NODE_ID;

            // Generate and schedule the message transmission
            if (!generate_send(address, & packet, payload -> messageType)) {
              // Failed to schedule the message transmission, handle the error
              dbgerror("radio_send", "Failed to schedule message transmission\n");
            } else {
              dbg("radio_send", "Node %hu Scheduled a CONNECT_ACK message to node %hu\n", TOS_NODE_ID, receivedMsg -> nodeID);
            }
          }
        }
        break;

      case CONNECT_ACK:
        dbg("radio_rec", "Received a CONNECT_ACK message from node %hu\n", receivedMsg -> nodeID);
        if (TOS_NODE_ID != 1 && call Timer1.isRunning()) {
          call Timer1.stop();
          dbg("timer", "Timer1 stopped.\n");
        }
        break;

      default:
        dbgerror("radio_rec", "Received an invalid message type\n");
        break;

      }

      return bufPtr;

    }
  }

  event void AMSend.sendDone(message_t * bufPtr, error_t error) {
    /* This event is triggered when a message is sent 
     *  Check if the packet is sent 
     */
    uint16_t i;

    if (error == SUCCESS) {

      // Unlocked the radio
      locked = FALSE;

      dbg("radio_send", "Packet sent...");
      dbg_clear("radio_send", " at time %s \n", sim_time_string());

    } else {
      dbgerror("radio_send", "Send done error!\n");
    }

    if (queueSize > 0) {

      // Shift the queue to remove the sent message
      for (i = 0; i < queueSize - 1; i++) {
        messageQueue[i] = messageQueue[i + 1];
        addressQueue[i] = addressQueue[i + 1];
      }

      queueSize--;

      // send the next message in the queue

      if (queueSize > 0) {
        call Timer0.startOneShot(generateRandomDelay(MIN_DELAY, MAX_DELAY));
      }
    }

  }

  // Function to generate random delays in milliseconds within a specified range
  uint16_t generateRandomDelay(uint16_t minDelay, uint16_t maxDelay) {
    uint16_t randomDelay = 0;
    // Ensure random number generation is seeded only once
    static bool isSeeded = FALSE;
    if (!isSeeded) {
      srand((uint16_t) TOS_NODE_ID); // Use node ID as the seed for randomization
      isSeeded = TRUE;
    }

    // Generate a random delay within the specified range
    randomDelay = minDelay + (rand() % (maxDelay - minDelay + 1));
    return randomDelay;
  }
}