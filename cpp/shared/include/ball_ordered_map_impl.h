#pragma once

// Insertion-ordered string map (Dart LinkedHashMap semantics).
// Shared by ball_shared.h (native engine) and ball_dyn.h (compiled programs).

#include <any>
#include <map>
#include <string>
#include <utility>
#include <vector>

struct BallOrderedMap {
    std::vector<std::pair<std::string, std::any>> entries_;
    std::map<std::string, size_t> index_;

    using key_type = std::string;
    using mapped_type = std::any;
    using value_type = std::pair<std::string, std::any>;
    using iterator = std::vector<value_type>::iterator;
    using const_iterator = std::vector<value_type>::const_iterator;

    std::any& operator[](const std::string& key) {
        auto it = index_.find(key);
        if (it == index_.end()) {
            index_[key] = entries_.size();
            entries_.emplace_back(key, std::any{});
        }
        return entries_[index_[key]].second;
    }

    const std::any& operator[](const std::string& key) const {
        return entries_.at(index_.at(key)).second;
    }

    const std::any& at(const std::string& key) const {
        return entries_.at(index_.at(key)).second;
    }

    iterator begin() { return entries_.begin(); }
    iterator end() { return entries_.end(); }
    const_iterator begin() const { return entries_.begin(); }
    const_iterator end() const { return entries_.end(); }

    size_t size() const { return entries_.size(); }
    bool empty() const { return entries_.empty(); }
    void clear() { entries_.clear(); index_.clear(); }
    size_t count(const std::string& key) const { return index_.count(key); }

    iterator find(const std::string& key) {
        auto it = index_.find(key);
        return it == index_.end() ? end() : entries_.begin() + static_cast<std::ptrdiff_t>(it->second);
    }
    const_iterator find(const std::string& key) const {
        auto it = index_.find(key);
        return it == index_.end() ? end() : entries_.begin() + static_cast<std::ptrdiff_t>(it->second);
    }

    void erase(const std::string& key) {
        auto it = index_.find(key);
        if (it == index_.end()) return;
        size_t idx = it->second;
        entries_.erase(entries_.begin() + static_cast<std::ptrdiff_t>(idx));
        index_.erase(it);
        for (size_t i = idx; i < entries_.size(); ++i)
            index_[entries_[i].first] = i;
    }

    void erase(iterator it) {
        if (it == end()) return;
        erase(it->first);
    }

    template<class InputIt>
    void insert(InputIt first, InputIt last) {
        for (; first != last; ++first)
            (*this)[first->first] = first->second;
    }
};
