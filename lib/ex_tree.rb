# encoding: UTF-8
# 트리 구조 테이블용 플러그인
# nasted tree 알고리즘을 사용하고 있으며 foreign_key를 key로 항목을 구분한다.
# todo
#   node delete 만들기
#   옮길 수 있는 노드인지 체크하는 method 만들기
module ExTree
  # ExTree용 예외처리 클래스
  class ExTreeError  < StandardError
  end

  module ActiveRecordMethods
    def self.included(base)
      base.extend ClassMethods
    end
    
    module ClassMethods
      def act_as_ex_tree(options = {})
        cattr_accessor :ex_tree_options
        self.ex_tree_options = {
                  :foreign_key => "parent_id"
                }.merge(options)

        extend  SingletonMethods
        include InstanceMethods unless included_modules.include?(InstanceMethods)
      end
    end

    module SingletonMethods
      # 노드를 반환한다
      #   todo: 각종 옵션을 추가하자. (ex:order 등..)
      def get_nodes(foreign_key)
        self.where("#{ex_tree_options[:foreign_key]} = ?", foreign_key).order("lft asc").all
      end
    end
    
    module InstanceMethods
      # 한곳에서 에러 처리
      def error_handle(method_name, err_msg, err_description, value_msg)
        logger.error("ExTree Error " + method_name + ": " + err_msg + " " + err_description + " [VALUES:" + value_msg + "]" )
        self.errors[:base] << err_msg
        raise ActiveRecord::Rollback
      end
      
      # 해당 노드 밑에 인자로 입력받은 노드를 삽입한다.
      # 새로운 노드 또는 기존의 노드를 인자로 넘길 수 있다.
      #   새로운 노드 추가하기
      #     t = ExTree.find(1)
      #     new_t = ExTree.new
      #     new_t.name = "test"
      #     t.append_child(new_t)
      #   기존 노드
      #     ExTree.find(1).append_child(2)
      def append_child(node)
        self.transaction do 
          begin
            # argument check
            if node.name.blank?
              raise ExTree::ExTreeError, "이름에 빈칸이 있습니다."
            end

            # get node length
            if node.new_record?
              node_size = 2
            else
              node_size = node.rgt - node.lft + 1
            end
            
            # make empty space
            self.class.update_all( "lft = lft + #{node_size}", ["#{ex_tree_options[:foreign_key]} = ? and lft > ?", self.read_attribute(ex_tree_options[:foreign_key]), self.rgt] )
            self.class.update_all( "rgt = rgt + #{node_size}", ["#{ex_tree_options[:foreign_key]} = ? and rgt >= ?", self.read_attribute(ex_tree_options[:foreign_key]), self.rgt] )
            
            # move node into parent
            if node.new_record?
              # 노드를 입력함
              node.send(ex_tree_options[:foreign_key] + "=", self.read_attribute(ex_tree_options[:foreign_key]))
              node.lft = self.rgt
              node.rgt = self.rgt + 1
              node.depth = self.depth + 1
              node.parent_id = self.id
              node.save
            else
              # 옮길 수 있는 노드인지 체크
              if node.lft <= self.lft && node.rgt >= self.rgt
                raise ExTree::ExTreeError, "부모노드를 자식노드로 옮길 수 없습니다."
              end
              if node.read_attribute(ex_tree_options[:foreign_key]) != self.read_attribute(ex_tree_options[:foreign_key])
                raise ExTree::ExTreeError, "같은 #{ex_tree_options[:foreign_key]} 끼리만 옮길 수 있습니다."
              end

              # 노드를 옮김
              reload_node = self.class.find(node.id)
              reload_node.parent_id = self.id
              reload_node.save
              self.class.update_all( "lft = lft + #{self.rgt - reload_node.lft},
                                  rgt = rgt + #{self.rgt - reload_node.lft},
                                  depth = depth + #{self.depth - node.depth + 1}", 
                                  ["lft >= '#{reload_node.lft}' and
                                  rgt <= '#{reload_node.rgt}' and
                                  #{ex_tree_options[:foreign_key]} = ?", self.read_attribute(ex_tree_options[:foreign_key])] )

              # 밀린 노드를 다시 정렬함
              self.class.update_all( "lft = lft - #{node_size}", ["lft > ? and #{ex_tree_options[:foreign_key]} = ?", node.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )
              self.class.update_all( "rgt = rgt - #{node_size}", ["rgt > ? and #{ex_tree_options[:foreign_key]} = ?", node.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )
            end
          rescue ExTree::ExTreeError => e
            self.error_handle("append_child()", "노드를 옮기던 중 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)
          rescue ActiveRecord::ActiveRecordError => e
            self.error_handle("append_child()", "SQL 에러가 발생하였습니다. ", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)
          rescue => e
            self.error_handle("append_child()", "알 수 없는 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)
          end      
        end
      end

      # 해당 노드 이전으로 입력받은 노드를 삽입한다.
      # 새로운 노드 또는 기존의 노드를 인자로 넘길 수 있다.
      #   새로운 노드
      #     t = ExTree.find(1)
      #     new_t = ExTree.new
      #     new_t.name = "test"
      #     t.insert_before(new_t)
      #   기존 노드
      #     ExTree.find(1).insert_before(2)
      def insert_before(node)
        self.transaction do 
          begin
            # get node length
            if node.new_record?
              node_size = 2
            else
              node_size = node.rgt - node.lft + 1
            end
            
            # make empty space
            self.class.update_all( "lft = lft + #{node_size}", ["#{ex_tree_options[:foreign_key]} = ? and lft >= ?", self.read_attribute(ex_tree_options[:foreign_key]), self.lft] )
            self.class.update_all( "rgt = rgt + #{node_size}", ["#{ex_tree_options[:foreign_key]} = ? and rgt > ?", self.read_attribute(ex_tree_options[:foreign_key]), self.lft] )

            # move node into parent
            if node.new_record?
              # 노드를 입력함
              node.send(ex_tree_options[:foreign_key] + "=", self.read_attribute(ex_tree_options[:foreign_key]))
              node.lft = self.lft
              node.rgt = self.lft + 1
              node.depth = self.depth
              node.parent_id = self.parent_id          
              node.save
            else
              # 옮길 수 있는 노드인지 체크
              if node.lft <= self.lft && node.rgt >= self.rgt
                raise ExTree::ExTreeError, "부모노드를 자식노드로 옮길 수 없습니다."
              end
              if node.read_attribute(ex_tree_options[:foreign_key]) != self.read_attribute(ex_tree_options[:foreign_key])
                raise ExTree::ExTreeError, "같은 #{ex_tree_options[:foreign_key]} 끼리만 옮길 수 있습니다."
              end

              # 노드를 옮김
              reload_node = self.class.find(node.id)
              reload_node.parent_id = self.parent_id
              reload_node.save
              self.class.update_all( "lft = lft + #{self.lft - reload_node.lft},
                                  rgt = rgt + #{self.lft - reload_node.lft},
                                  depth = depth + #{self.depth - node.depth}", 
                                  ["lft >= '#{reload_node.lft}' and
                                  rgt <= '#{reload_node.rgt}' and
                                  #{ex_tree_options[:foreign_key]} = ?", self.read_attribute(ex_tree_options[:foreign_key])] )

              # 밀린 노드를 다시 정렬함
              self.class.update_all( "lft = lft - #{node_size}", ["lft > ? and #{ex_tree_options[:foreign_key]} = ?", node.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )
              self.class.update_all( "rgt = rgt - #{node_size}", ["rgt > ? and #{ex_tree_options[:foreign_key]} = ?", node.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )
            end
          rescue ExTree::ExTreeError => e
            self.error_handle("insert_before()", "노드를 옮기던 중 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)
          rescue ActiveRecord::ActiveRecordError => e
            self.error_handle("insert_before()", "SQL 에러가 발생하였습니다. ", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)    
          rescue => e
            self.error_handle("insert_before()", "알 수 없는 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml + ",node - " + node.to_yaml)
          end      
        end    
      end

      # 해당 노드 다음으로 입력받은 노드를 삽입한다.
      # 새로운 노드 또는 기존의 노드를 인자로 넘길 수 있다.
      #   새로운 노드
      #     t = ExTree.find(1)
      #     new_t = ExTree.new
      #     new_t.name = "test"
      #     t.insert_after(new_t)
      #   기존 노드
      #     ExTree.find(1).insert_after(2)
      def insert_after(node)
        next_node = self.class.where("parent_id = ? and lft > ? and rgt > ?", self.parent_id, self.lft, self.rgt)
                      .order("lft asc").first
        if next_node.nil?
          self.parent_node.append_child(node);
        else
          next_node.insert_before(node);
        end
      end

      # 해당 노드를 삭제한다.
      #   t = ExTree.find(2)
      #   t.remove_node
      def remove_node
        self.transaction do 
          begin
            node_size = self.rgt - self.lft + 1
            
            # delete nodes
            nodes = self.class.find(:all, :conditions => ["lft >= ? and rgt <= ? and #{ex_tree_options[:foreign_key]} = ?", self.lft, self.rgt, self.read_attribute(ex_tree_options[:foreign_key])])
            self.class.destroy_all(["lft >= ? and rgt <= ?", self.lft, self.rgt])
          
            # 노드를 옮김
            self.class.update_all( "lft = lft - #{node_size}", ["lft > ? and #{ex_tree_options[:foreign_key]} = ?", self.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )
            self.class.update_all( "rgt = rgt - #{node_size}", ["rgt > ? and #{ex_tree_options[:foreign_key]} = ?", self.rgt, self.read_attribute(ex_tree_options[:foreign_key])] )            
          rescue ExTree::ExTreeError => e
            self.error_handle("remove_node()", "노드를 삭제하던 중 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml)
          rescue ActiveRecord::ActiveRecordError => e
            self.error_handle("remove_node()", "SQL 에러가 발생하였습니다. ", e.message, 
                              "self - " + self.to_yaml)    
          rescue => e
            self.error_handle("remove_node()", "알 수 없는 에러가 발생하였습니다.", e.message, 
                              "self - " + self.to_yaml)
          end
        end
      end

      # 최상단 노드부터 현재 노드까지 이름을 리턴한다.
      def full_path(sep = " ")
        return self.name if self.root?

        ret = ""
        begin
          result = self.class.find_by_sql("SELECT parent.name " +
            "FROM devlog_categories AS node, " +
            "devlog_categories AS parent " +
            "WHERE node.lft BETWEEN parent.lft AND parent.rgt " +
            "AND parent.depth != '-1' " +
            "AND node.id = '#{self.id}' " +
            "ORDER BY parent.lft");
          
          if result.size > 1
            for i in 0...result.size - 1
              ret << result[i].name + sep
            end
            ret << result[result.size-1].name
          else
            ret = result[0].name
          end
        rescue ExTree::ExTreeError => e
          self.error_handle("full_path()", "노드를 삭제하던 중 에러가 발생하였습니다.", e.message, 
                            "self - " + self.to_yaml)         
        rescue ActiveRecord::ActiveRecordError => e
          self.error_handle("full_path()", "SQL에러가 발생하였습니다. ", e.message, 
                            "self - " + self.to_yaml)
        rescue => e
          self.error_handle("full_path()", "알 수 없는 에러가 발생하였습니다. ", e.message, 
                            "self - " + self.to_yaml)
        end
        ret
      end

      # 부모 노드를 불러온다
      def parent_node
        unless self.root? # ROOT 가 아닐때만
          self.class.where("lft < ? and rgt > ? and depth = ? and #{ex_tree_options[:foreign_key]} = ?", self.lft, self.rgt, self.depth - 1, self.read_attribute(ex_tree_options[:foreign_key])).first
        end
      end
      
      # 최상위 노드인가?
      def root?
        self.depth == -1
      end
    end
  end
end

ActiveRecord::Base.class_eval { include ExTree::ActiveRecordMethods }